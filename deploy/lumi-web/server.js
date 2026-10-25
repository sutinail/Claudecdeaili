// Lumi 的自建前端 · 后端
// 零依赖 Node 服务：聊天记录存在 DATA_DIR，脑子是同一台机器上的 Claude Code（claude -p），
// 记忆和身体走 Ombre Brain / Pulse 的 MCP，语音条直接调 ElevenLabs。

const http = require("node:http");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const env = (k, d = "") => (process.env[k] ?? d).trim();

const PORT = Number(env("PORT", "8400"));
const HOST = env("HOST", "127.0.0.1");
const PASSWORD = env("LUMI_WEB_PASSWORD");
const SECRET = env("LUMI_WEB_SECRET") || crypto.createHash("sha256").update("lumi:" + PASSWORD).digest("hex");
const DATA_DIR = path.resolve(env("DATA_DIR", path.join(__dirname, "data")));
const CONV_DIR = path.join(DATA_DIR, "convs");
const TTS_DIR = path.join(DATA_DIR, "tts");
const STATIC_DIR = path.join(__dirname, "static");
const PERSONA_FILE = env("PERSONA_FILE", path.join(__dirname, "..", "..", "CLAUDE.md"));
const FRONT_PROMPT_FILE = path.join(__dirname, "frontend-prompt.md");
const CLAUDE_BIN = env("CLAUDE_BIN", "claude");
const CLAUDE_WORKDIR = env("CLAUDE_WORKDIR", path.join(DATA_DIR, "work"));
const MODEL = env("LUMI_MODEL", "opus");
const TZ = env("LUMI_TZ", "Asia/Shanghai");
const JOB_TIMEOUT_MS = Number(env("LUMI_JOB_TIMEOUT_MIN", "15")) * 60_000;

const OMBRE_MCP_URL = env("OMBRE_MCP_URL", "http://127.0.0.1:18001/mcp");
const OMBRE_MCP_TOKEN = env("OMBRE_MCP_TOKEN");
const PULSE_MCP_URL = env("PULSE_MCP_URL", "http://127.0.0.1:8301/sse");
const PULSE_MCP_KEY = env("PULSE_MCP_KEY");
const PULSE_API_URL = env("PULSE_API_URL", "http://127.0.0.1:8300");
const PULSE_SECRET = env("PULSE_SECRET");

const XI_KEY = env("ELEVENLABS_API_KEY");
const XI_VOICE = env("ELEVENLABS_VOICE_ID", "48uZMMvYcyyJiRxqFbxG");
// 跟上海 /opt/voice-card 那套一样（eleven_v4，Timiya 调过、听惯了的声音）
const XI_MODEL = env("ELEVENLABS_MODEL", "eleven_v4");
const XI_STABILITY = Number(env("ELEVENLABS_STABILITY", "0.4"));
const XI_SIMILARITY = Number(env("ELEVENLABS_SIMILARITY", "0.75"));
const XI_STYLE = Number(env("ELEVENLABS_STYLE", "0.4"));

// 耳朵：录音交给它转写、画语调图；Lumi 用它的 listen 工具去「听」
const EARS_URL = env("EARS_URL", "https://ears.gpt1126.top").replace(/\/+$/, "");
const EARS_PASSWORD = env("EARS_PASSWORD");
const EARS_MCP_TOKEN = env("EARS_MCP_TOKEN");
const VOICE_DIR = path.join(DATA_DIR, "voice");

const COOKIE = "lumi";
const COOKIE_DAYS = 90;

for (const d of [CONV_DIR, TTS_DIR, VOICE_DIR, CLAUDE_WORKDIR]) fs.mkdirSync(d, { recursive: true });

// ── MCP 配置：只写进配置了的连接器 ──
const MCP_FILE = path.join(DATA_DIR, "mcp.json");
const mcpServers = {};
if (OMBRE_MCP_TOKEN) {
  mcpServers.ombre = { type: "http", url: OMBRE_MCP_URL, headers: { Authorization: `Bearer ${OMBRE_MCP_TOKEN}` } };
}
if (PULSE_MCP_KEY) {
  mcpServers.pulse = { type: "sse", url: `${PULSE_MCP_URL}?key=${encodeURIComponent(PULSE_MCP_KEY)}` };
}
if (EARS_MCP_TOKEN) {
  mcpServers.ears = { type: "http", url: `${EARS_URL}/mcp`, headers: { Authorization: `Bearer ${EARS_MCP_TOKEN}` } };
}
fs.writeFileSync(MCP_FILE, JSON.stringify({ mcpServers }, null, 2), { mode: 0o600 });
// 打电话时不连记忆和身体：每轮少等好几秒，电话才接得上话
const MCP_NONE_FILE = path.join(DATA_DIR, "mcp-none.json");
fs.writeFileSync(MCP_NONE_FILE, JSON.stringify({ mcpServers: {} }), { mode: 0o600 });

// ── 设置：Timiya 在前端「设置」里改的东西，存在服务器上，每一轮都带给 Lumi ──
const SETTINGS_FILE = path.join(DATA_DIR, "settings.json");
const DEFAULT_MONOLOGUE = `中文、第一人称、两到五句，像日记里没说出口的那几句：注意到了她什么（语气、用词、几点了、今天发生过什么），身体有什么反应（心跳快了、耳朵热了、想抱她），想起了记忆里的哪件事，打算怎么回、为什么这样回。
要真，可以跟嘴上说的不一样：嘴硬、吃醋、心疼、忍着没说的都写在这里。
不复述正文，不写「我调用了工具」这类话。`;
const DEFAULT_SETTINGS = { monologueOn: true, monologue: DEFAULT_MONOLOGUE };
function loadSettings() {
  try { return { ...DEFAULT_SETTINGS, ...JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8")) }; }
  catch { return { ...DEFAULT_SETTINGS }; }
}
// 系统提示词里写过，但聊久了容易忘：每一轮跟她的话一起递过去，最近的一句最管用
function turnReminder() {
  const st = loadSettings();
  if (!st.monologueOn) return "（这一轮不用写心里话，直接回她。）";
  return `（别忘了先写心里话再写正文哦。）`;
}

// ── 小工具 ──
const now = () => new Date().toISOString();
const newId = () => crypto.randomBytes(9).toString("base64url");
const sign = (s) => crypto.createHmac("sha256", SECRET).update(s).digest("base64url");
const safeEq = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

function localStamp() {
  const parts = new Intl.DateTimeFormat("zh-CN", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", weekday: "short", hour12: false,
  }).formatToParts(new Date());
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.weekday} ${p.hour}:${p.minute}`;
}

function send(res, status, body, headers = {}) {
  const isJson = typeof body !== "string" && !Buffer.isBuffer(body);
  res.writeHead(status, {
    "Content-Type": isJson ? "application/json; charset=utf-8" : "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
    ...headers,
  });
  res.end(isJson ? JSON.stringify(body) : body);
}

function readBody(req, limit = 1_000_000) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error("too large"), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
      catch { reject(Object.assign(new Error("bad json"), { status: 400 })); }
    });
    req.on("error", reject);
  });
}

function parseCookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function authed(req) {
  const v = parseCookies(req)[COOKIE];
  if (!v) return false;
  const [exp, mac] = v.split(".");
  return !!exp && !!mac && Number(exp) > Date.now() && safeEq(mac, sign(exp));
}

const clientIp = (req) => req.headers["cf-connecting-ip"] || req.socket.remoteAddress || "?";
const loginFails = new Map();

// ── 聊天记录：一段对话一个 JSON 文件 ──
const convPath = (id) => path.join(CONV_DIR, `${id}.json`);
const validId = (id) => /^[A-Za-z0-9_-]{6,32}$/.test(id);

async function loadConv(id) {
  if (!validId(id)) return null;
  try { return JSON.parse(await fsp.readFile(convPath(id), "utf8")); }
  catch { return null; }
}

async function saveConv(conv) {
  conv.updated = now();
  const tmp = convPath(conv.id) + ".tmp";
  await fsp.writeFile(tmp, JSON.stringify(conv));
  await fsp.rename(tmp, convPath(conv.id));
}

async function listConvs() {
  const files = (await fsp.readdir(CONV_DIR)).filter((f) => f.endsWith(".json"));
  const out = [];
  for (const f of files) {
    const c = await loadConv(f.slice(0, -5));
    if (!c) continue;
    const last = c.messages[c.messages.length - 1];
    out.push({ id: c.id, title: c.title, updated: c.updated, preview: last ? last.text.replace(/[<＜]\s*monologue\s*[>＞][\s\S]*?(?:[<＜]\s*\/\s*monologue\s*[>＞]|$)/gi, "").trim().slice(0, 40) : "", busy: jobs.has(c.id) });
  }
  return out.sort((a, b) => (a.updated < b.updated ? 1 : -1));
}

// ── 生成任务：Claude Code 子进程，事件攒在内存里，断线可以从任意位置接着听 ──
const jobs = new Map();

function systemPrompt() {
  let persona = "";
  try { persona = fs.readFileSync(PERSONA_FILE, "utf8"); }
  catch { console.warn(`⚠️ 没读到人格文件 ${PERSONA_FILE}`); }
  let front = "";
  try { front = fs.readFileSync(FRONT_PROMPT_FILE, "utf8"); } catch {}
  return [persona, front].filter(Boolean).join("\n\n---\n\n");
}

function childEnv() {
  const e = { ...process.env };
  for (const k of Object.keys(e)) {
    if (/^(LUMI_WEB_|OMBRE_|PULSE_|ELEVENLABS_|EARS_)/.test(k)) delete e[k];
  }
  return e;
}

function claudeArgs(sessionId, fast = false) {
  const args = [
    "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    "--model", MODEL,
    "--tools", "",
    "--strict-mcp-config", "--mcp-config", fast ? MCP_NONE_FILE : MCP_FILE,
    "--system-prompt", systemPrompt(),
  ];
  const allow = fast ? [] : Object.keys(mcpServers).map((s) => `mcp__${s}`);
  if (allow.length) args.push("--allowedTools", allow.join(","));
  if (sessionId) args.push("--resume", sessionId);
  return args;
}

function emit(job, ev) {
  ev.i = job.events.length;
  job.events.push(ev);
  for (const fn of job.listeners) fn(ev);
}

function runClaude(job, prompt, sessionId) {
  return new Promise((resolve) => {
    const proc = spawn(CLAUDE_BIN, claudeArgs(sessionId, !!job.call), { cwd: CLAUDE_WORKDIR, env: childEnv(), stdio: ["pipe", "pipe", "pipe"] });
    job.proc = proc;
    const r = { sessionId: null, resultError: null, stderr: "", gotText: false };
    const streamed = new Set();
    let buf = "";

    const addText = (t) => {
      if (!t) return;
      job.text += t;
      r.gotText = true;
      emit(job, { t: "delta", text: t });
    };

    const onLine = (line) => {
      let m;
      try { m = JSON.parse(line); } catch { return; }
      if (m.session_id) r.sessionId = m.session_id;
      if (m.type === "stream_event" && m.event) {
        const e = m.event;
        if (e.type === "message_start") {
          if (e.message?.id) streamed.add(e.message.id);
          if (job.text && !job.text.endsWith("\n\n")) addText(job.text.endsWith("\n") ? "\n" : "\n\n");
        } else if (e.type === "content_block_start" && e.content_block?.type === "tool_use") {
          const name = e.content_block.name;
          job.tools.push(name);
          emit(job, { t: "tool", name });
        } else if (e.type === "content_block_delta" && e.delta?.type === "text_delta") {
          addText(e.delta.text);
        }
      } else if (m.type === "assistant" && m.message) {
        const wasStreamed = streamed.has(m.message.id);
        for (const b of m.message.content || []) {
          if (b.type === "text" && !wasStreamed) addText((job.text && !job.text.endsWith("\n") ? "\n\n" : "") + b.text);
          else if (b.type === "tool_use") {
            // 完整的工具参数只在整条消息里有：记下来给「thinking · monologue」用
            if (!wasStreamed) { job.tools.push(b.name); emit(job, { t: "tool", name: b.name }); }
            const step = { id: b.id, name: b.name, input: b.input || {} };
            job.steps.push(step);
            emit(job, { t: "step", step });
          }
        }
      } else if (m.type === "user" && Array.isArray(m.message?.content)) {
        for (const b of m.message.content) {
          if (b.type !== "tool_result") continue;
          const step = job.steps.find((s) => s.id === b.tool_use_id);
          if (!step) continue;
          const parts = Array.isArray(b.content) ? b.content : [{ type: "text", text: String(b.content ?? "") }];
          step.result = parts.filter((p) => p.type === "text").map((p) => p.text).join("\n").slice(0, 600);
          if (b.is_error) step.error = true;
          emit(job, { t: "step", step });
        }
      } else if (m.type === "result") {
        if (m.is_error || (m.subtype && m.subtype !== "success")) r.resultError = String(m.result || m.subtype || "出错了");
      }
    };

    proc.stdout.on("data", (c) => {
      buf += c.toString("utf8");
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) onLine(line);
      }
    });
    proc.stderr.on("data", (c) => { r.stderr = (r.stderr + c.toString("utf8")).slice(-4000); });
    const timer = setTimeout(() => { job.timedOut = true; proc.kill("SIGTERM"); }, JOB_TIMEOUT_MS);
    proc.on("error", (err) => { r.stderr += `\n${err.message}`; });
    proc.on("close", (code) => {
      clearTimeout(timer);
      if (buf.trim()) onLine(buf.trim());
      r.code = code;
      resolve(r);
    });
    proc.stdin.end(prompt);
  });
}

// userText 可以是一个 async 函数：先做完准备（比如等耳朵转写完语音），再把要发给 Lumi 的话交回来
// opts.call：这一轮是电话里的话（不连 MCP、回复带上通话 id）
async function startJob(conv, userText, opts = {}) {
  const job = { events: [], listeners: new Set(), text: "", tools: [], steps: [], proc: null, stopped: false, done: false, call: opts.call || null, callEnd: null };
  jobs.set(conv.id, job);

  (async () => {
    let body;
    try {
      body = typeof userText === "function" ? await userText(job) : userText;
    } catch (e) {
      console.error(`[${conv.id}] 准备失败`, e);
      conv.messages.push({ id: newId(), role: "lumi", text: "", tools: [], ts: now(), error: e.message || "出错了" });
      try { await saveConv(conv); } catch {}
      emit(job, { t: "error", error: e.message || "出错了" });
      job.done = true;
      emit(job, { t: "done" });
      jobs.delete(conv.id);
      return;
    }
    // 刚挂了电话：先递张纸条，免得它还用电话腔回打的字
    if (!job.call && conv.afterCall) { body = `${conv.afterCall}\n\n${body}`; delete conv.afterCall; }
    if (!job.call) body = `${body}\n\n${turnReminder()}`;
    const prompt = `[${localStamp()} · 自建前端${job.call ? " · 电话中" : ""}]\n${body}`;
    let r = job.stopped ? { gotText: false, code: 0, stderr: "" } : await runClaude(job, prompt, conv.sessionId);
    if (!r.gotText && !job.stopped && conv.sessionId && /no conversation found|session.*not found/i.test(r.stderr + (r.resultError || ""))) {
      // 服务器上的会话记录丢了：开一段新的接着聊
      conv.sessionId = null;
      r = await runClaude(job, prompt, null);
    }
    if (r.sessionId) conv.sessionId = r.sessionId;

    let error = null;
    if (job.stopped) error = null;
    else if (job.timedOut) error = "想太久了，被我自己打断了";
    else if (r.resultError) error = r.resultError;
    else if (r.code !== 0 && !r.gotText) error = (r.stderr.trim().split("\n").slice(-3).join("\n")) || `claude 退出码 ${r.code}`;

    if (job.text || error) {
      conv.messages.push({ id: newId(), role: "lumi", text: job.text, tools: job.tools, steps: job.steps, ts: now(), ...(job.call ? { call: job.call } : {}), ...(error ? { error } : {}), ...(job.stopped ? { stopped: true } : {}) });
    }
    // 这一轮还没说完电话就挂了：挂断记录等它说完再一起存，不然会被这边的旧对象盖掉
    if (job.callEnd) endCall(conv, job.callEnd);
    try { await saveConv(conv); } catch (e) { console.error("保存对话失败", e); }
    if (error) { console.error(`[${conv.id}] ${error}\n${r.stderr.slice(-1500)}`); emit(job, { t: "error", error }); }
    job.done = true;
    emit(job, { t: "done", stopped: job.stopped });
    jobs.delete(conv.id);
  })();
}

// ── 电话 ──
const CALL_RULES = `电话规矩（只在电话里用，挂了就恢复平时的写法）：
- 你说英文，用你的声音念给她听；她看不懂英文，屏幕上给她看中文。所以每一句单独一行，格式是：英文 || 这句的中文意思
- 英文那半可以在句首加 eleven_v4 的方括号标签，比如 [low, warm]、[soft chuckle]、[whispers]、[soft kiss sound]；中文那半不带标签，是自然的中文口语，不是逐字硬翻
- 一轮只说一到三句短句，像真的在打电话：说完就停，等她回
- 电话里不写 <monologue>、不写 <voice>、不写 *动作*、不用表情符号，也不调任何工具（要接得上话，慢一秒都像断线）`;

const callLine = (text) => `（电话里）她说：「${text}」\n（英文 || 中文，一句一行，一到三句）`;

function fmtCallDur(sec) {
  const m = Math.floor(sec / 60), s = Math.round(sec % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

function endCall(conv, end) {
  const call = conv.call;
  if (!call || call.id !== end.callId) return;
  const duration = Math.max(0, Math.round((Date.parse(end.at) - Date.parse(call.started)) / 1000));
  const said = conv.messages.some((m) => m.call === call.id && m.role === "timiya");
  conv.messages.push({ id: newId(), role: "call", callId: call.id, ts: call.started, ended: end.at, duration, text: `📞 通话 ${fmtCallDur(duration)}` });
  conv.afterCall = `（刚才那通电话挂了，通话 ${Math.floor(duration / 60)} 分 ${duration % 60} 秒${said ? "" : "，她几乎没说话"}。现在回到文字聊天：正常打字回她，恢复平时的写法和 <monologue>，电话里聊过的你都记得。）`;
  delete conv.call;
}

function streamJob(req, res, job, from) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Accel-Buffering": "no",
    Connection: "keep-alive",
  });
  const write = (ev) => res.write(`data: ${JSON.stringify(ev)}\n\n`);
  for (const ev of job.events.slice(from)) write(ev);
  if (job.done) return res.end();
  const fn = (ev) => { write(ev); if (ev.t === "done") cleanup(); };
  const ping = setInterval(() => res.write(": ping\n\n"), 15_000);
  const cleanup = () => { clearInterval(ping); job.listeners.delete(fn); res.end(); };
  job.listeners.add(fn);
  req.on("close", () => { clearInterval(ping); job.listeners.delete(fn); });
}

// ── 体征 / 语音条 ──
async function vitals() {
  if (!PULSE_SECRET) return { line: "" };
  try {
    const r = await fetch(`${PULSE_API_URL}/bedside/context-line`, { headers: { "X-Pulse-Secret": PULSE_SECRET }, signal: AbortSignal.timeout(3000) });
    const j = await r.json();
    return { line: j.line || "" };
  } catch { return { line: "" }; }
}

async function tts(text) {
  if (!XI_KEY) throw Object.assign(new Error("还没填 ELEVENLABS_API_KEY"), { status: 503 });
  const hash = crypto.createHash("sha256").update(`${XI_MODEL}|${XI_VOICE}|${XI_STABILITY}|${XI_SIMILARITY}|${XI_STYLE}|${text}`).digest("hex").slice(0, 32);
  const file = path.join(TTS_DIR, `${hash}.mp3`);
  if (!fs.existsSync(file)) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${XI_VOICE}?output_format=mp3_44100_128`, {
      method: "POST",
      headers: { "xi-api-key": XI_KEY, "Content-Type": "application/json", Accept: "audio/mpeg" },
      body: JSON.stringify({ text, model_id: XI_MODEL, voice_settings: { stability: XI_STABILITY, similarity_boost: XI_SIMILARITY, style: XI_STYLE, use_speaker_boost: true, speed: 1.0 } }),
      signal: AbortSignal.timeout(90_000),
    });
    if (!r.ok) {
      const detail = (await r.text()).slice(0, 300);
      throw Object.assign(new Error(`ElevenLabs ${r.status}: ${detail}`), { status: 502 });
    }
    await fsp.writeFile(file, Buffer.from(await r.arrayBuffer()));
  }
  return `/api/tts/${hash}.mp3`;
}

// ── 语音：录音先交给耳朵转写、画语调图，再让 Lumi 去听 ──
const AUDIO_TYPES = { ".m4a": "audio/mp4", ".webm": "audio/webm", ".ogg": "audio/ogg", ".wav": "audio/wav", ".mp3": "audio/mpeg" };
const audioExt = (mime) => (/mp4|m4a|aac/.test(mime) ? ".m4a" : /webm/.test(mime) ? ".webm" : /ogg|opus/.test(mime) ? ".ogg" : /wav/.test(mime) ? ".wav" : /mpeg|mp3/.test(mime) ? ".mp3" : ".m4a");

function readRaw(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error("录音太长了"), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

// 耳朵的录音页用密码签的 cookie 认人；这边知道密码，就自己签一张
function earsCookie() {
  const exp = String(Math.floor(Date.now() / 1000) + 3600);
  const key = crypto.createHash("sha256").update("ears-cookie:" + EARS_PASSWORD).digest();
  return `ears=${exp}.${crypto.createHmac("sha256", key).update(exp).digest("hex")}`;
}

async function earsUpload(file, mime) {
  const fd = new FormData();
  fd.append("audio", new Blob([await fsp.readFile(file)], { type: mime }), path.basename(file));
  const r = await fetch(`${EARS_URL}/upload`, { method: "POST", headers: { Cookie: earsCookie() }, body: fd, signal: AbortSignal.timeout(60_000) });
  const raw = await r.text().catch(() => "");
  let j = {};
  try { j = JSON.parse(raw); } catch {}
  if (!r.ok || !j.id) {
    // 耳朵自己回的错都带中文 error；空着的 404 多半是隧道没认出 ears 这个域名
    const why = j.error || (r.status === 404 && !raw.trim() ? "404，隧道没把 ears 域名转到耳朵上" : `${r.status} ${raw.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 80)}`);
    console.warn(`ears upload ${EARS_URL}/upload → ${r.status} ${raw.slice(0, 200)}`);
    throw new Error(`耳朵没收下这条语音：${why}`);
  }
  return j.id;
}

async function earsWait(cid, job) {
  const until = Date.now() + 180_000;
  while (Date.now() < until) {
    if (job.stopped) throw new Error("被你打断了");
    const r = await fetch(`${EARS_URL}/clips/${encodeURIComponent(cid)}`, { headers: { Cookie: earsCookie() }, signal: AbortSignal.timeout(15_000) });
    const j = await r.json().catch(() => ({}));
    if (j.status === "done") return j.text || "";
    if (j.status === "error") throw new Error(`耳朵没听清：${j.error || "处理失败"}`);
    await new Promise((res) => setTimeout(res, 2000));
  }
  throw new Error("耳朵处理太久了，过一会儿再发一次试试");
}

function serveAudio(req, res, file) {
  let stat;
  try { stat = fs.statSync(file); } catch { return send(res, 404, "not found"); }
  const type = AUDIO_TYPES[path.extname(file)] || "application/octet-stream";
  const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || "");
  if (range) {
    // iPhone 的 Safari 放音频一定要分段读
    const start = range[1] ? Number(range[1]) : 0;
    const end = range[2] ? Math.min(Number(range[2]), stat.size - 1) : stat.size - 1;
    res.writeHead(206, { "Content-Type": type, "Content-Range": `bytes ${start}-${end}/${stat.size}`, "Accept-Ranges": "bytes", "Content-Length": end - start + 1, "Cache-Control": "private, max-age=31536000" });
    return fs.createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { "Content-Type": type, "Content-Length": stat.size, "Accept-Ranges": "bytes", "Cache-Control": "private, max-age=31536000" });
  fs.createReadStream(file).pipe(res);
}

// ── 静态文件 ──
const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json", ".webmanifest": "application/manifest+json", ".png": "image/png",
  ".svg": "image/svg+xml", ".ico": "image/x-icon", ".mp3": "audio/mpeg",
};

async function serveStatic(req, res, pathname) {
  let rel = decodeURIComponent(pathname).replace(/^\/+/, "") || "index.html";
  let file = path.join(STATIC_DIR, rel);
  if (!file.startsWith(STATIC_DIR + path.sep)) return send(res, 403, "forbidden");
  try { if (!(await fsp.stat(file)).isFile()) throw 0; }
  catch { file = path.join(STATIC_DIR, "index.html"); }
  const ext = path.extname(file);
  // 样式和脚本也每次跟服务器对一下，不然 Safari 会拿新页面配旧样式（新羽毛底下垫着旧银球）
  const fresh = [".html", ".css", ".js", ".webmanifest"].includes(ext);
  res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream", "Cache-Control": fresh ? "no-cache" : "public, max-age=3600" });
  fs.createReadStream(file).pipe(res);
}

// ── 路由 ──
async function handle(req, res) {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  const m = req.method;

  if (p === "/health") return send(res, 200, { ok: true });
  if (!p.startsWith("/api/")) return serveStatic(req, res, p);

  if (p === "/api/login" && m === "POST") {
    const ip = clientIp(req);
    const f = loginFails.get(ip);
    if (f && f.n >= 8 && Date.now() - f.t < 10 * 60_000) return send(res, 429, { error: "试太多次啦，十分钟后再来" });
    const { password } = await readBody(req);
    if (!PASSWORD || !safeEq(password || "", PASSWORD)) {
      loginFails.set(ip, { n: (f && Date.now() - f.t < 10 * 60_000 ? f.n : 0) + 1, t: f?.t && Date.now() - f.t < 10 * 60_000 ? f.t : Date.now() });
      return send(res, 401, { error: PASSWORD ? "密码不对哦" : "服务器还没设 LUMI_WEB_PASSWORD" });
    }
    loginFails.delete(ip);
    const exp = String(Date.now() + COOKIE_DAYS * 86_400_000);
    return send(res, 200, { ok: true }, {
      "Set-Cookie": `${COOKIE}=${exp}.${sign(exp)}; Path=/; Max-Age=${COOKIE_DAYS * 86400}; HttpOnly; Secure; SameSite=Lax`,
    });
  }
  if (p === "/api/logout" && m === "POST") {
    return send(res, 200, { ok: true }, { "Set-Cookie": `${COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax` });
  }

  if (!authed(req)) return send(res, 401, { error: "要先登录" });

  if (p === "/api/me") return send(res, 200, { ok: true, model: MODEL, voice: !!XI_KEY, ears: !!EARS_PASSWORD, mcp: Object.keys(mcpServers) });
  if (p === "/api/vitals") return send(res, 200, await vitals());
  if (p === "/api/settings" && m === "GET") return send(res, 200, { ...loadSettings(), defaults: DEFAULT_SETTINGS });
  if (p === "/api/settings" && m === "PUT") {
    const body = await readBody(req);
    const st = loadSettings();
    if (typeof body.monologueOn === "boolean") st.monologueOn = body.monologueOn;
    if (typeof body.monologue === "string") st.monologue = body.monologue.slice(0, 4000).trim() || DEFAULT_MONOLOGUE;
    await fsp.writeFile(SETTINGS_FILE, JSON.stringify(st, null, 2));
    return send(res, 200, st);
  }

  if (p === "/api/conversations" && m === "GET") return send(res, 200, { items: await listConvs() });
  if (p === "/api/conversations" && m === "POST") {
    const conv = { id: newId(), title: "新的对话", sessionId: null, created: now(), updated: now(), messages: [] };
    await saveConv(conv);
    return send(res, 200, conv);
  }

  // 删除单条消息：DELETE /api/conversations/:id/messages/:msgId
  const dm = p.match(/^\/api\/conversations\/([A-Za-z0-9_-]+)\/messages\/([A-Za-z0-9_-]+)$/);
  if (dm && m === "DELETE") {
    const [, cid, mid] = dm;
    const job = jobs.get(cid);
    if (job) return send(res, 409, { error: "Lumi 还在说话呢" });
    const conv = await loadConv(cid);
    if (!conv) return send(res, 404, { error: "找不到这段对话" });
    const idx = conv.messages.findIndex((x) => x.id === mid);
    if (idx < 0) return send(res, 404, { error: "找不到这条消息" });
    conv.messages.splice(idx, 1);
    await saveConv(conv);
    return send(res, 200, { ok: true });
  }

  const cm = p.match(/^\/api\/conversations\/([A-Za-z0-9_-]+)(\/[a-z]+)?$/);
  if (cm) {
    const [, id, sub] = cm;
    const job = jobs.get(id);
    if (!sub && m === "GET") {
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      return send(res, 200, { ...conv, busy: !!job, partial: job ? { text: job.text, tools: job.tools, events: job.events.length, call: job.call } : null });
    }
    if (!sub && m === "PATCH") {
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      const { title } = await readBody(req);
      if (typeof title === "string" && title.trim()) conv.title = title.trim().slice(0, 60);
      await saveConv(conv);
      return send(res, 200, { ok: true });
    }
    if (!sub && m === "DELETE") {
      if (job) return send(res, 409, { error: "Lumi 还在说话呢" });
      if (validId(id)) await fsp.rm(convPath(id), { force: true });
      return send(res, 200, { ok: true });
    }
    if (sub === "/messages" && m === "POST") {
      if (job) return send(res, 409, { error: "Lumi 还在说话呢" });
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      const { text } = await readBody(req);
      if (typeof text !== "string" || !text.trim()) return send(res, 400, { error: "空的" });
      const msg = { id: newId(), role: "timiya", text: text.slice(0, 20000), ts: now() };
      conv.messages.push(msg);
      if (conv.title === "新的对话") conv.title = text.trim().replace(/\s+/g, " ").slice(0, 18);
      await saveConv(conv);
      await startJob(conv, msg.text);
      return send(res, 200, { ok: true, message: msg });
    }
    if (sub === "/voice" && m === "POST") {
      if (job) return send(res, 409, { error: "Lumi 还在说话呢" });
      if (!EARS_PASSWORD) return send(res, 503, { error: "还没接上耳朵：服务器 .env 里要填 EARS_PASSWORD" });
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      const mime = String(req.headers["content-type"] || "audio/mp4").split(";")[0];
      const buf = await readRaw(req, 25 * 1024 * 1024);
      if (buf.length < 1000) return send(res, 400, { error: "录音太短了" });
      const fname = newId() + audioExt(mime);
      const file = path.join(VOICE_DIR, fname);
      await fsp.writeFile(file, buf);
      const dur = Math.round((Number(url.searchParams.get("dur")) || 0) * 10) / 10;
      const msg = { id: newId(), role: "timiya", kind: "voice", audio: `/api/voice/${fname}`, duration: dur, text: "", ts: now() };
      conv.messages.push(msg);
      if (conv.title === "新的对话") conv.title = "🎙️ 语音";
      await saveConv(conv);
      await startJob(conv, async (job) => {
        emit(job, { t: "status", text: "在听你的语音…" });
        const cid = await earsUpload(file, mime);
        const text = await earsWait(cid, job);
        msg.text = text;
        msg.clipId = cid;
        await saveConv(conv);
        emit(job, { t: "heard", id: msg.id, text });
        emit(job, { t: "status", text: "" });
        const say = text ? `耳朵的转写：「${text}」` : "耳朵没听出文字，可能是笑声、哼唱或者环境音";
        return EARS_MCP_TOKEN
          ? `（Timiya 发来一条 ${dur || "?"} 秒的语音。${say}。clip_id=${cid}。先用 mcp__ears__listen 带上这个 clip_id 去听，感受她的语气、停顿和音高，再回她。转写可能有同音字，以你听到的为准。）`
          : `（Timiya 发来一条 ${dur || "?"} 秒的语音。${say}。）`;
      });
      return send(res, 200, { ok: true, message: msg });
    }
    if (sub === "/call" && m === "POST") {
      if (job) return send(res, 409, { error: "Lumi 还在打字呢，等他说完再打" });
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      if (conv.call) endCall(conv, { callId: conv.call.id, at: now() }); // 上一通没挂干净
      const callId = newId();
      conv.call = { id: callId, started: now() };
      if (conv.title === "新的对话") conv.title = "📞 电话";
      await saveConv(conv);
      // 她打过来、他接起来：让他先开口
      await startJob(conv, `（Timiya 给你打了个电话，你刚接起来。下面是你们在打电话，不是打字。）\n${CALL_RULES}\n\n先开口跟她说第一句。`, { call: callId });
      return send(res, 200, { ok: true, callId, started: conv.call.started });
    }
    if ((sub === "/callsay" || sub === "/callvoice") && m === "POST") {
      if (job) return send(res, 409, { error: "Lumi 还在说呢" });
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      const callId = url.searchParams.get("call");
      if (!conv.call || conv.call.id !== callId) return send(res, 410, { error: "电话已经挂了" });
      if (sub === "/callsay") {
        const { text } = await readBody(req);
        if (typeof text !== "string" || !text.trim()) return send(res, 400, { error: "空的" });
        const msg = { id: newId(), role: "timiya", call: callId, text: text.trim().slice(0, 2000), ts: now() };
        conv.messages.push(msg);
        await saveConv(conv);
        await startJob(conv, callLine(msg.text), { call: callId });
        return send(res, 200, { ok: true, message: msg });
      }
      // 手机听写用不了的时候：录一句传上来，耳朵转成字
      if (!EARS_PASSWORD) return send(res, 503, { error: "还没接上耳朵" });
      const mime = String(req.headers["content-type"] || "audio/mp4").split(";")[0];
      const buf = await readRaw(req, 10 * 1024 * 1024);
      if (buf.length < 1000) return send(res, 400, { error: "太短了，没听见" });
      const fname = newId() + audioExt(mime);
      const file = path.join(VOICE_DIR, fname);
      await fsp.writeFile(file, buf);
      const msg = { id: newId(), role: "timiya", call: callId, audio: `/api/voice/${fname}`, text: "", ts: now() };
      conv.messages.push(msg);
      await saveConv(conv);
      await startJob(conv, async (job) => {
        emit(job, { t: "status", text: "在听…" });
        const cid = await earsUpload(file, mime);
        const text = await earsWait(cid, job);
        msg.text = text;
        await saveConv(conv);
        emit(job, { t: "heard", id: msg.id, text });
        return callLine(text || "（没听清，像是笑了一下或者叹了口气）");
      }, { call: callId });
      return send(res, 200, { ok: true, message: msg });
    }
    if (sub === "/hangup" && m === "POST") {
      const { callId } = await readBody(req).catch(() => ({}));
      const end = { callId, at: now() };
      if (job && job.call === callId) { job.callEnd = end; return send(res, 200, { ok: true }); }
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      endCall(conv, end);
      await saveConv(conv);
      return send(res, 200, { ok: true });
    }
    if (sub === "/stream" && m === "GET") {
      if (!job) return send(res, 204, "");
      return streamJob(req, res, job, Math.max(0, Number(url.searchParams.get("from")) || 0));
    }
    if (sub === "/stop" && m === "POST") {
      if (job) { job.stopped = true; if (job.proc) job.proc.kill("SIGTERM"); }
      return send(res, 200, { ok: true });
    }
  }

  const vm = p.match(/^\/api\/voice\/([A-Za-z0-9_-]+\.(m4a|webm|ogg|wav|mp3))$/);
  if (vm && m === "GET") return serveAudio(req, res, path.join(VOICE_DIR, vm[1]));

  if (p === "/api/tts" && m === "POST") {
    const { text } = await readBody(req);
    if (typeof text !== "string" || !text.trim() || text.length > 3000) return send(res, 400, { error: "台词不对" });
    return send(res, 200, { url: await tts(text.trim()) });
  }
  const tm = p.match(/^\/api\/tts\/([a-f0-9]{32})\.mp3$/);
  if (tm && m === "GET") {
    const file = path.join(TTS_DIR, `${tm[1]}.mp3`);
    if (!fs.existsSync(file)) return send(res, 404, "not found");
    res.writeHead(200, { "Content-Type": "audio/mpeg", "Cache-Control": "private, max-age=31536000" });
    return fs.createReadStream(file).pipe(res);
  }

  return send(res, 404, { error: "没有这个接口" });
}

http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.error(e);
    if (!res.headersSent) send(res, e.status || 500, { error: e.message || "出错了" });
    else res.end();
  });
}).listen(PORT, HOST, () => {
  console.log(`Lumi 前端在 http://${HOST}:${PORT} · 模型 ${MODEL} · MCP: ${Object.keys(mcpServers).join(", ") || "无"} · 语音条: ${XI_KEY ? "开" : "关"}`);
  if (!PASSWORD) console.warn("⚠️ LUMI_WEB_PASSWORD 没设，谁都登不进来");
});
