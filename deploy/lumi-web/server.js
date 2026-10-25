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
const XI_MODEL = env("ELEVENLABS_MODEL", "eleven_v3");
const XI_STABILITY = Number(env("ELEVENLABS_STABILITY", "0.5"));
const XI_SIMILARITY = Number(env("ELEVENLABS_SIMILARITY", "0.78"));

const COOKIE = "lumi";
const COOKIE_DAYS = 90;

for (const d of [CONV_DIR, TTS_DIR, CLAUDE_WORKDIR]) fs.mkdirSync(d, { recursive: true });

// ── MCP 配置：只写进配置了的连接器 ──
const MCP_FILE = path.join(DATA_DIR, "mcp.json");
const mcpServers = {};
if (OMBRE_MCP_TOKEN) {
  mcpServers.ombre = { type: "http", url: OMBRE_MCP_URL, headers: { Authorization: `Bearer ${OMBRE_MCP_TOKEN}` } };
}
if (PULSE_MCP_KEY) {
  mcpServers.pulse = { type: "sse", url: `${PULSE_MCP_URL}?key=${encodeURIComponent(PULSE_MCP_KEY)}` };
}
fs.writeFileSync(MCP_FILE, JSON.stringify({ mcpServers }, null, 2), { mode: 0o600 });

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
    out.push({ id: c.id, title: c.title, updated: c.updated, preview: last ? last.text.slice(0, 40) : "", busy: jobs.has(c.id) });
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
    if (/^(LUMI_WEB_|OMBRE_|PULSE_|ELEVENLABS_)/.test(k)) delete e[k];
  }
  return e;
}

function claudeArgs(sessionId) {
  const args = [
    "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    "--model", MODEL,
    "--tools", "",
    "--strict-mcp-config", "--mcp-config", MCP_FILE,
    "--system-prompt", systemPrompt(),
  ];
  const allow = Object.keys(mcpServers).map((s) => `mcp__${s}`);
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
    const proc = spawn(CLAUDE_BIN, claudeArgs(sessionId), { cwd: CLAUDE_WORKDIR, env: childEnv(), stdio: ["pipe", "pipe", "pipe"] });
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
      } else if (m.type === "assistant" && m.message && !streamed.has(m.message.id)) {
        // 没有逐字流的版本：整条消息一起到
        for (const b of m.message.content || []) {
          if (b.type === "text") addText((job.text && !job.text.endsWith("\n") ? "\n\n" : "") + b.text);
          else if (b.type === "tool_use") { job.tools.push(b.name); emit(job, { t: "tool", name: b.name }); }
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

async function startJob(conv, userText) {
  const job = { events: [], listeners: new Set(), text: "", tools: [], proc: null, stopped: false, done: false };
  jobs.set(conv.id, job);
  const prompt = `[${localStamp()} · 自建前端]\n${userText}`;

  (async () => {
    let r = await runClaude(job, prompt, conv.sessionId);
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
      conv.messages.push({ id: newId(), role: "lumi", text: job.text, tools: job.tools, ts: now(), ...(error ? { error } : {}), ...(job.stopped ? { stopped: true } : {}) });
    }
    try { await saveConv(conv); } catch (e) { console.error("保存对话失败", e); }
    if (error) { console.error(`[${conv.id}] ${error}\n${r.stderr.slice(-1500)}`); emit(job, { t: "error", error }); }
    job.done = true;
    emit(job, { t: "done", stopped: job.stopped });
    jobs.delete(conv.id);
  })();
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
  const hash = crypto.createHash("sha256").update(`${XI_MODEL}|${XI_VOICE}|${XI_STABILITY}|${XI_SIMILARITY}|${text}`).digest("hex").slice(0, 32);
  const file = path.join(TTS_DIR, `${hash}.mp3`);
  if (!fs.existsSync(file)) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${XI_VOICE}?output_format=mp3_44100_128`, {
      method: "POST",
      headers: { "xi-api-key": XI_KEY, "Content-Type": "application/json", Accept: "audio/mpeg" },
      body: JSON.stringify({ text, model_id: XI_MODEL, voice_settings: { stability: XI_STABILITY, similarity_boost: XI_SIMILARITY } }),
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
  const fresh = ext === ".html" || rel === "sw.js" || ext === ".webmanifest";
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

  if (p === "/api/me") return send(res, 200, { ok: true, model: MODEL, voice: !!XI_KEY, mcp: Object.keys(mcpServers) });
  if (p === "/api/vitals") return send(res, 200, await vitals());

  if (p === "/api/conversations" && m === "GET") return send(res, 200, { items: await listConvs() });
  if (p === "/api/conversations" && m === "POST") {
    const conv = { id: newId(), title: "新的对话", sessionId: null, created: now(), updated: now(), messages: [] };
    await saveConv(conv);
    return send(res, 200, conv);
  }

  const cm = p.match(/^\/api\/conversations\/([A-Za-z0-9_-]+)(\/[a-z]+)?$/);
  if (cm) {
    const [, id, sub] = cm;
    const job = jobs.get(id);
    if (!sub && m === "GET") {
      const conv = await loadConv(id);
      if (!conv) return send(res, 404, { error: "找不到这段对话" });
      return send(res, 200, { ...conv, busy: !!job, partial: job ? { text: job.text, tools: job.tools, events: job.events.length } : null });
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
    if (sub === "/stream" && m === "GET") {
      if (!job) return send(res, 204, "");
      return streamJob(req, res, job, Math.max(0, Number(url.searchParams.get("from")) || 0));
    }
    if (sub === "/stop" && m === "POST") {
      if (job && job.proc) { job.stopped = true; job.proc.kill("SIGTERM"); }
      return send(res, 200, { ok: true });
    }
  }

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
