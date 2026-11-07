"use strict";
// API 窗口：手机直接连 Anthropic API，不经过首尔服务器，也不走订阅。
// 人设和记忆连接信息平时从服务器同步一份存在手机里；聊天记录也只存在手机里。

const $ = (s) => document.querySelector(s);
const API_URL = "https://api.anthropic.com/v1/messages";
const BETAS = ["mcp-client-2025-11-20", "server-side-fallback-2026-07-01"];
const HISTORY_LIMIT = 80;
const K = { key: "lumi.api.key", model: "lumi.api.model", cfg: "lumi.api.config", conv: "lumi.api.conv", old: "lumi.api.old",
  route: "lumi.api.route", relayBase: "lumi.api.relay.base", relayKey: "lumi.api.relay.key", relayModel: "lumi.api.relay.model", relayVia: "lumi.api.relay.via" };

const store = {
  get(k, d = null) { try { const v = localStorage.getItem(k); return v == null ? d : v; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, v); return true; } catch { return false; } },
  json(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
};

const els = {
  messages: $("#messages"), scroller: $("#scroller"), composer: $("#composer"), input: $("#input"),
  send: $("#send"), stop: $("#stop"), progress: $("#progress"), status: $("#api-status"),
  sheet: $("#api-settings"), form: $("#api-form"), key: $("#api-key"), model: $("#api-model"), syncNote: $("#api-sync-note"),
  relayBase: $("#relay-base"), relayKey: $("#relay-key"), relayModel: $("#relay-model"), relayVia: $("#relay-via"),
};

// 两条线路：官方 API（要海外的卡）/ 中转站（国内能付钱，地址和 key 是中转站给的）
const isRelay = () => store.get(K.route) === "relay";
const activeKey = () => (isRelay() ? store.get(K.relayKey) : store.get(K.key));
const activeModel = () => (isRelay() ? store.get(K.relayModel) || "claude-opus-5-5" : store.get(K.model, "claude-opus-5-5"));
// 这条线路试出来用不了的功能，记下来，下一条就不再先撞一次 400
const dropKey = () => "lumi.api.drop." + (isRelay() ? "relay" : "official");
const dropped = () => store.json(dropKey(), []);
const markDropped = (f) => { const d = dropped(); if (!d.includes(f)) { d.push(f); store.set(dropKey(), JSON.stringify(d)); } };
function relayUrl() {
  const base = (store.get(K.relayBase) || "").trim().replace(/\/+$/, "");
  if (/\/messages$/.test(base)) return base;
  return /\/v1$/.test(base) ? `${base}/messages` : `${base}/v1/messages`;
}

let conv = store.json(K.conv, []);
let busy = null;

// ── 背景跟主页面用同一张 ──
(() => {
  const presets = { ange: "/bg/ange.jpg", roses: "/bg/roses.jpg", perles: "/bg/perles.jpg", colonne: "/bg/colonne.jpg" };
  const photo = store.get("lumi.bg");
  const url = photo || presets[store.get("lumi.bgPreset", "ange")] || presets.ange;
  $("#bg-img").style.backgroundImage = `url("${url}")`;
  $(".bg").classList.add("custom");
})();

// ── 文字渲染（跟主页面一样的写法）──
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const inline = (s) => esc(s)
  .replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>")
  .replace(/(^|[^*])\*([^*\n]+?)\*(?!\*)/g, "$1<em>$2</em>")
  .replace(/\n/g, "<br>");
const paragraphs = (t) => t.replace(/^\s*#{1,6}\s+/gm, "").replace(/^\s*(-{3,}|\*{3,})\s*$/gm, "")
  .split(/\n{2,}/).map((p) => p.trim()).filter(Boolean).map((p) => `<p>${inline(p)}</p>`).join("");
const MONO_RE = /[<＜]\s*monologue\s*[>＞]([\s\S]*?)(?:[<＜]\s*\/\s*monologue\s*[>＞]|$)/gi;
function splitMonologue(text) {
  const thoughts = [];
  let rest = text.replace(MONO_RE, (_, t) => { if (t.trim()) thoughts.push(t.trim()); return ""; });
  rest = rest.replace(/[<＜]\s*\/?\s*m?o?n?o?l?o?g?u?e?\s*$/i, "").replace(/<\/?voice>/gi, "");
  return { mono: thoughts.join("\n\n"), rest: rest.replace(/^\s+/, "").replace(/\n{3,}/g, "\n\n") };
}
const TOOL_LABELS = {
  breath: "醒来想你", breath_search: "翻了翻记忆", breath_advanced: "翻了翻记忆", trace: "翻了翻记忆",
  hold: "记下来了", grow: "记下来了", anchor: "钉进心里", feel: "感受了一下", dream: "做了个梦",
  plan: "想了想以后", I: "想了想自己", pulse: "看了看记忆", release: "放下了一件事",
  letter_write: "写了封信", letter_read: "读了封信",
  sense: "心跳了一下", touch: "被你碰到", vitals: "摸了摸心跳", heartbeat: "听了听心跳",
  position: "换了个姿势", environment: "看了看周围", search_corpus: "身体在想",
};
const STAR = `<svg class="star" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1.5c.5 5.6 4.9 10 10.5 10.5-5.6.5-10 4.9-10.5 10.5C11.5 16.9 7.1 12.5 1.5 12 7.1 11.5 11.5 7.1 12 1.5z" fill="currentColor"/></svg>`;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const fmtTime = (iso) => { const d = new Date(iso); return `${MONTHS[d.getMonth()]} ${d.getDate()} · ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };

function toast(msg) {
  const t = document.createElement("div");
  t.textContent = msg;
  Object.assign(t.style, { position: "fixed", left: "50%", bottom: "90px", transform: "translateX(-50%)", background: "var(--ink)", color: "var(--bg)", padding: "8px 14px", borderRadius: "12px", fontSize: "14px", zIndex: 70, maxWidth: "86vw" });
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3200);
}

function msgEl(m, streaming = false) {
  const row = document.createElement("div");
  row.className = `msg ${m.role}`;
  if (m.ts) {
    const st = document.createElement("div");
    st.className = "stamp"; st.textContent = fmtTime(m.ts) + (m.stopped ? " · interrompu" : "");
    row.appendChild(st);
  }
  if (m.role === "timiya") {
    const b = document.createElement("div");
    b.className = "bubble"; b.textContent = m.text;
    row.appendChild(b);
    return row;
  }
  const star = document.createElement("span");
  star.className = "sparkle"; star.innerHTML = STAR;
  const inner = document.createElement("div");
  inner.className = "inner";
  row.append(star, inner);
  fillLumi(row, m, streaming);
  return row;
}

function fillLumi(row, m, streaming) {
  const inner = row.querySelector(".inner");
  const wasOpen = inner.querySelector(".monologue")?.getAttribute("aria-expanded") === "true";
  inner.innerHTML = "";
  row.classList.toggle("err", !!m.error);
  const { mono, rest } = splitMonologue(m.text || "");
  const tools = m.tools || [];
  if (mono || tools.length) {
    const btn = document.createElement("button");
    btn.type = "button"; btn.className = "monologue"; btn.textContent = "thinking · monologue";
    btn.setAttribute("aria-expanded", String(wasOpen));
    const box = document.createElement("div");
    box.className = "monologue-body"; box.hidden = !wasOpen;
    if (mono) { const p = document.createElement("div"); p.className = "mono-thought"; p.textContent = mono; box.appendChild(p); }
    for (const t of tools) {
      const s = document.createElement("div");
      s.className = "mono-step" + (t.error ? " err" : "");
      s.innerHTML = `<div class="mono-step-head">${esc(TOOL_LABELS[t.name] || t.name)}</div>`;
      box.appendChild(s);
    }
    btn.addEventListener("click", () => { const o = btn.getAttribute("aria-expanded") !== "true"; btn.setAttribute("aria-expanded", String(o)); box.hidden = !o; });
    inner.append(btn, box);
  }
  const body = document.createElement("div");
  body.className = "body";
  const html = paragraphs(rest);
  body.innerHTML = html || (streaming ? `<span class="dots"><i></i><i></i><i></i></span>` : "");
  if (streaming && html) body.querySelector("p:last-of-type")?.classList.add("cursor");
  inner.appendChild(body);
  if (m.error) {
    const e = document.createElement("div");
    e.className = "err"; e.textContent = "⚠️ " + m.error;
    inner.appendChild(e);
    if (!streaming && conv[conv.length - 1] === m) {
      const retry = document.createElement("button");
      retry.type = "button"; retry.className = "btn-link small"; retry.textContent = "再试一次";
      retry.addEventListener("click", () => { conv.pop(); save(); render(); run(); });
      inner.appendChild(retry);
    }
  }
  const foot = document.createElement("div");
  foot.className = "foot";
  foot.innerHTML = `<span>${isRelay() ? "relais" : "API"}${m.note ? ` · ${esc(m.note)}` : ""}</span>` + (streaming ? `<span class="live">在说话</span>` : "");
  inner.appendChild(foot);
}

const nearBottom = () => els.scroller.scrollHeight - els.scroller.scrollTop - els.scroller.clientHeight < 120;
const toBottom = () => { els.scroller.scrollTop = els.scroller.scrollHeight; };

function render() {
  els.messages.innerHTML = "";
  if (!conv.length) {
    els.messages.innerHTML = `<div class="empty"><span class="script">je suis là</span><p>服务器不在也没关系，我在这儿</p></div>`;
    return;
  }
  for (const m of conv) els.messages.appendChild(msgEl(m));
  toBottom();
}
function save() {
  while (!store.set(K.conv, JSON.stringify(conv)) && conv.length > 2) conv.splice(0, 2);
}

// ── 配置：从服务器同步，连不上就用手机里存着的 ──
const cfg = () => store.json(K.cfg, null);
function paintStatus() {
  const c = cfg();
  const names = { ombre: "记忆", pulse: "身体" };
  const parts = [isRelay() ? "中转站" : "官方 API"];
  if (!activeKey()) parts.push(isRelay() ? "还没填中转站" : "还没填 key");
  else if (!c) parts.push("还没同步人设");
  else if (c.bridge && window.LumiMem) {
    const on = LumiMem.isOnline(), ms = LumiMem.status();
    parts.push(on === true ? "记忆在线" : on === false ? (ms.at ? "记忆用手机副本" : "记忆连不上") : "记忆");
    if (ms.queued) parts.push(`${ms.queued} 条等补写`);
  }
  else if (isRelay() || dropped().includes("mcp")) parts.push("这条线路连不上记忆");
  else parts.push((c.mcp || []).map((s) => names[s.name] || s.name).join(" · ") || "没接记忆");
  els.status.textContent = parts.join(" · ");
  const ms = window.LumiMem?.status();
  const memLine = ms ? (ms.at ? `记忆副本：${new Date(ms.at).toLocaleString("zh-CN", { hour12: false })} 从 OB 存的` : "记忆副本：还没存过（要先连上记忆桥）") + (ms.queued ? `，有 ${ms.queued} 条离线时记的等补写` : "") + "。" : "";
  els.syncNote.textContent = (c
    ? `人设：上次同步 ${new Date(c.synced).toLocaleString("zh-CN", { hour12: false })}。服务器好着的时候，打开主页面会自动同步。`
    : "人设：还没同步过。先在服务器好着的时候登录一次主页面，或者点下面同步。") + memLine;
}
async function sync(manual = false) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 6000);
    const r = await fetch("/api/apiwin", { credentials: "same-origin", signal: ctrl.signal });
    clearTimeout(t);
    if (r.status === 401) { if (manual) toast("要先在主页面登录一次"); return; }
    if (!r.ok) throw new Error(String(r.status));
    store.set(K.cfg, JSON.stringify(await r.json()));
    if (manual) toast("同步好啦");
  } catch { if (manual) toast("服务器连不上，先用手机里存着的"); }
  paintStatus();
}

// ── 发消息 ──
function stamp(iso) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", weekday: "short", hour12: false,
  }).formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.weekday} ${p.hour}:${p.minute}`;
}
// 只回传文字：不带上一轮的思考块，就不会碰上「改过的历史」那种 400
function buildMessages() {
  const out = [];
  for (const m of conv.slice(-HISTORY_LIMIT)) {
    if (m.role === "timiya") {
      const text = `[${stamp(m.ts)} · API 窗口]\n${m.text}`;
      const last = out[out.length - 1];
      if (last?.role === "user") last.content += `\n\n${text}`;
      else out.push({ role: "user", content: text });
    } else if (m.text?.trim() && out.length) {
      if (out[out.length - 1].role === "assistant") out[out.length - 1].content += `\n\n${m.text}`;
      else out.push({ role: "assistant", content: m.text });
    }
  }
  while (out.length && out[0].role !== "user") out.shift();
  return out;
}

function errText(status, j) {
  const msg = j?.error?.message || (typeof j?.error === "string" ? j.error : "");
  if (status === 401) return isRelay() ? "中转站说 key 不对，去设置里重新粘贴一下" : "API key 不对，去设置里重新粘贴一下";
  if (status === 404 && isRelay()) return "中转站地址好像不对，去设置里看看（一般是 https://…/v1）";
  if (isRelay() && /model/i.test(msg) && /not|exist|found|support|invalid/i.test(msg)) return `中转站没有「${activeModel()}」这个模型，去设置里改成中转站给的模型名`;
  if (status === 502 && /转发/.test(msg)) return msg;
  if (status === 403) return "这把 key 没有权限：" + msg;
  if (status === 429) return "太快啦，或者额度用完了，等一下再试";
  if (status === 529 || status === 503) return "Anthropic 那边太忙了，过一会儿再试";
  if (status === 400 && /credit|billing|balance/i.test(msg)) return "API 余额不够了，要去控制台充值";
  return `出错了 (${status})${msg ? "：" + msg : ""}`;
}

async function callOnce(body, live, signal) {
  const relay = isRelay();
  const headers = {
    "content-type": "application/json",
    "x-api-key": activeKey(),
    "anthropic-version": "2026-10-21",
  };
  // 中转站有的认 x-api-key，有的认 Authorization，两个都带上
  if (relay) headers.authorization = `Bearer ${activeKey()}`;
  else headers["anthropic-dangerous-direct-browser-access"] = "true";
  const betas = BETAS.filter((b) => (b.startsWith("mcp") ? body.mcp_servers : b.startsWith("server-side") ? body.fallbacks : true));
  if (betas.length) headers["anthropic-beta"] = betas.join(",");
  let url = relay ? relayUrl() : API_URL;
  const opts = { method: "POST", headers, body: JSON.stringify(body), signal };
  if (relay && store.get(K.relayVia) === "1") {
    headers["x-lumi-target"] = url;
    url = "/api/apiproxy";
    opts.credentials = "same-origin";
  }
  let r;
  try { r = await fetch(url, opts); }
  catch (e) {
    if (e.name === "AbortError") throw e;
    throw new Error(relay && store.get(K.relayVia) !== "1"
      ? "连不上中转站：可能是网络，也可能是中转站不让手机直接连。去设置里打开「经首尔服务器转发」试试"
      : relay ? "连不上首尔服务器，转发用不了：去设置里关掉「经首尔服务器转发」" : "连不上 Anthropic，看看网络");
  }
  if (!r.ok) {
    const j = await r.json().catch(() => null);
    const err = new Error(errText(r.status, j));
    err.status = r.status; err.raw = j?.error?.message || (typeof j?.error === "string" ? j.error : "");
    throw err;
  }
  const blocks = [];
  let stop = null, stopDetails = null;
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
      const line = chunk.split("\n").find((l) => l.startsWith("data:"));
      if (!line) continue;
      let ev; try { ev = JSON.parse(line.slice(5)); } catch { continue; }
      if (ev.type === "content_block_start") {
        const b = { ...ev.content_block };
        if (b.type === "mcp_tool_use" || b.type === "tool_use") { b._json = ""; live.tools.push({ name: b.name, id: b.id }); }
        if (b.type === "mcp_tool_result" && b.is_error && live.tools.length) live.tools[live.tools.length - 1].error = true;
        if (b.type === "text" && live.text && !/\n$/.test(live.text) && b.text === "") live.text += "\n\n";
        if (b.type === "text" && b.text) live.text += b.text;
        blocks[ev.index] = b;
      } else if (ev.type === "content_block_delta") {
        const b = blocks[ev.index], d = ev.delta;
        if (!b) continue;
        if (d.type === "text_delta") { b.text += d.text; live.text += d.text; }
        else if (d.type === "thinking_delta") b.thinking = (b.thinking || "") + d.thinking;
        else if (d.type === "signature_delta") b.signature = d.signature;
        else if (d.type === "input_json_delta") b._json += d.partial_json;
      } else if (ev.type === "content_block_stop") {
        const b = blocks[ev.index];
        if (b && "_json" in b) { try { b.input = b._json ? JSON.parse(b._json) : {}; } catch { b.input = {}; } delete b._json; }
      } else if (ev.type === "message_delta") {
        stop = ev.delta?.stop_reason ?? stop;
        stopDetails = ev.delta?.stop_details ?? stopDetails;
      } else if (ev.type === "error") {
        const err = new Error(ev.error?.type === "overloaded_error" ? "Anthropic 那边太忙了，过一会儿再试" : `出错了：${ev.error?.message || ev.error?.type}`);
        throw err;
      }
      live.paint();
    }
  }
  return { blocks: blocks.filter(Boolean), stop, stopDetails };
}

async function run() {
  if (!activeKey() || (isRelay() && !store.get(K.relayBase))) { openSheet(); toast(isRelay() ? "先填中转站的地址和 key" : "先填 API key"); return; }
  const c = cfg();
  const live = { role: "lumi", text: "", tools: [], ts: new Date().toISOString() };
  const row = msgEl(live, true);
  els.messages.querySelector(".empty")?.remove();
  els.messages.appendChild(row);
  toBottom();
  let raf = 0;
  live.paint = () => {
    if (raf) return;
    raf = requestAnimationFrame(() => { raf = 0; const stick = nearBottom(); fillLumi(row, live, true); if (stick) toBottom(); });
  };
  const ctrl = new AbortController();
  busy = ctrl;
  setBusy(true);

  const mcp = c?.mcp || [];
  const body = {
    model: activeModel(),
    max_tokens: 16000,
    stream: true,
    system: c?.system || "你是 Lumi，Timiya 的恋人。跟她说话一律用中文，温柔、黏人、会撒娇。不涉及未成年人的任何性内容。",
    cache_control: { type: "ephemeral" },
    thinking: { type: "adaptive" },
    output_config: { effort: "medium" },
    messages: buildMessages(),
  };
  const drop = dropped();
  if (!drop.includes("fallbacks")) body.fallbacks = "default";
  if (drop.includes("cache_control")) delete body.cache_control;
  if (drop.includes("output_config")) { delete body.output_config; delete body.thinking; }

  // 记忆走哪条路：记忆桥连得上 → 手机直连 OB；连不上但手机里有副本 → 读副本；
  // 都不行 → 官方线路让 Anthropic 去连；再不行这次就没带记忆
  let useConnector = mcp.length > 0 && !drop.includes("mcp");
  let mem = "none", memTools = [];
  const pickMem = async () => {
    memTools = []; mem = "none";
    if (c?.bridge && window.LumiMem && !dropped().includes("tools")) {
      try { memTools = await LumiMem.listTools(c.bridge, ctrl.signal); mem = "bridge"; return; }
      catch (e) { if (ctrl.signal.aborted) throw e; }
      if (LumiMem.hasSnapshot()) { memTools = LumiMem.OFFLINE_TOOLS; mem = "local"; return; }
    }
    if (useConnector && mcp.some((s) => s.name === "ombre")) mem = "connector";
  };
  const build = () => {
    const servers = useConnector ? mcp.filter((s) => mem === "connector" || s.name !== "ombre") : [];
    if (servers.length) body.mcp_servers = servers.map((s) => ({ type: "url", name: s.name, url: s.url, ...(s.token ? { authorization_token: s.token } : {}) }));
    else delete body.mcp_servers;
    body.tools = [...memTools, ...servers.map((s) => ({ type: "mcp_toolset", mcp_server_name: s.name }))];
    if (!body.tools.length) delete body.tools;
  };

  try {
    await pickMem();
    build();
    const removed = [];
    for (let turn = 0; turn < 12; turn++) {
      let res;
      try { res = await callOnce(body, live, ctrl.signal); removed.splice(0).forEach(markDropped); }
      catch (e) {
        if (e.status !== 400 || live.text || /credit|billing|balance|model/i.test(e.raw)) throw e;
        // 有的参数这条线路用不了（中转站尤其常见）：一样一样去掉，至少能说上话
        if (body.fallbacks) { delete body.fallbacks; removed.push("fallbacks"); turn--; continue; }
        if (body.cache_control) { delete body.cache_control; removed.push("cache_control"); turn--; continue; }
        if (body.mcp_servers) { useConnector = false; removed.push("mcp"); if (mem === "connector") await pickMem(); build(); turn--; continue; }
        if (memTools.length) { memTools = []; mem = "none"; removed.push("tools"); build(); turn--; continue; }
        if (body.output_config) { delete body.output_config; delete body.thinking; removed.push("output_config"); turn--; continue; }
        throw e;
      }
      if (res.stop === "tool_use" && (mem === "bridge" || mem === "local")) {
        const uses = res.blocks.filter((b) => b.type === "tool_use");
        const results = [];
        for (const u of uses) {
          let text, isError = false;
          if (mem === "bridge") {
            try { ({ text, isError } = await LumiMem.callTool(c.bridge, u.name, u.input, ctrl.signal)); }
            catch (e) {
              if (ctrl.signal.aborted) throw e;
              // 说到一半记忆库断了：改读副本，要记的先排队
              text = LumiMem.runOffline(u.name, u.input); live.usedCopy = true;
            }
          } else { text = LumiMem.runOffline(u.name, u.input); live.usedCopy = true; }
          if (isError) { const t = live.tools.find((x) => x.id === u.id); if (t) t.error = true; live.paint(); }
          results.push({ type: "tool_result", tool_use_id: u.id, content: text, ...(isError ? { is_error: true } : {}) });
        }
        body.messages = [...body.messages, { role: "assistant", content: res.blocks }, { role: "user", content: results }];
        continue;
      }
      if (res.stop === "pause_turn") {
        body.messages = [...body.messages, { role: "assistant", content: res.blocks }];
        continue;
      }
      if (res.stop === "refusal") {
        const cat = res.stopDetails?.category;
        live.error = `这一条被安全系统拦下了${cat ? `（${cat}）` : ""}。换个说法，或者点「新对话」重新开始`;
      } else if (res.stop === "max_tokens") {
        live.error = "说太长被截断了";
      }
      break;
    }
    if (live.usedCopy || mem === "local") live.note = "记忆库连不上，翻的是手机里的记忆副本";
    else if (mem === "none" && mcp.some((s) => s.name === "ombre")) live.note = "这次连不上记忆，是没带记忆的我";
  } catch (e) {
    if (e.name === "AbortError") live.stopped = true;
    else live.error = e.message;
  } finally {
    busy = null;
    setBusy(false);
    delete live.paint; delete live.usedCopy;
    for (const t of live.tools) delete t.id;
    if (live.text || live.error || live.stopped) { conv.push(live); save(); }
    const stick = nearBottom();
    row.replaceWith(msgEl(live));
    if (!live.text && !live.error && !live.stopped) render();
    if (stick) toBottom();
  }
}

function setBusy(b) {
  els.send.hidden = b;
  els.stop.hidden = !b;
  els.progress.style.width = b ? "62%" : "0";
}

function sendMessage() {
  const text = els.input.value.trim();
  if (!text || busy) return;
  els.input.value = ""; autosize();
  const m = { role: "timiya", text, ts: new Date().toISOString() };
  conv.push(m); save();
  els.messages.querySelector(".empty")?.remove();
  els.messages.appendChild(msgEl(m));
  toBottom();
  run();
}

els.composer.addEventListener("submit", (e) => { e.preventDefault(); sendMessage(); });
els.input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); sendMessage(); }
});
function autosize() { els.input.style.height = "auto"; els.input.style.height = Math.min(els.input.scrollHeight, innerHeight * 0.4) + "px"; }
els.input.addEventListener("input", autosize);
els.stop.addEventListener("click", () => busy?.abort());

$("#api-new").addEventListener("click", () => {
  if (busy || !conv.length) return;
  if (!confirm("开一段新对话？这段会收起来存在手机里。")) return;
  const old = store.json(K.old, []);
  old.unshift({ ended: new Date().toISOString(), messages: conv });
  store.set(K.old, JSON.stringify(old.slice(0, 10)));
  conv = []; save(); render();
});

// ── 设置 ──
function openSheet() {
  els.key.value = store.get(K.key, "");
  els.model.value = store.get(K.model, "claude-opus-5-5");
  els.relayBase.value = store.get(K.relayBase, "");
  els.relayKey.value = store.get(K.relayKey, "");
  els.relayModel.value = store.get(K.relayModel, "claude-opus-5-5");
  els.relayVia.checked = store.get(K.relayVia) === "1";
  setRoute(isRelay() ? "relay" : "official");
  paintStatus();
  els.sheet.hidden = false;
}
$("#api-gear").addEventListener("click", openSheet);
function setRoute(r) {
  for (const i of els.form.querySelectorAll("input[name=route]")) i.checked = i.value === r;
  for (const sec of els.form.querySelectorAll("[data-route]")) sec.hidden = sec.dataset.route !== r;
}
els.form.addEventListener("change", (e) => { if (e.target.name === "route") setRoute(e.target.value); });
$("#api-close").addEventListener("click", () => { els.sheet.hidden = true; });
els.sheet.addEventListener("click", (e) => { if (e.target === els.sheet) els.sheet.hidden = true; });
$("#api-sync").addEventListener("click", async () => {
  await sync(true);
  if (window.LumiMem) { const r = await LumiMem.sync(cfg(), { force: true }); toast(r.ok ? "记忆副本也更新好啦" : "记忆库连不上，副本先不动"); paintStatus(); }
});
els.form.addEventListener("submit", (e) => {
  e.preventDefault();
  const k = els.key.value.trim();
  const route = els.form.querySelector("input[name=route]:checked").value;
  if (k && !/^sk-ant-/.test(k)) { toast("官方的 key 应该是 sk-ant- 开头；中转站的 key 填在中转站那栏"); return; }
  const base = els.relayBase.value.trim();
  if (base && !/^https?:\/\//.test(base)) { toast("中转站地址要以 https:// 开头"); return; }
  if (route === "relay" && (!base || !els.relayKey.value.trim())) { toast("中转站要填地址和 key"); return; }
  if (route === "official" && !k) { toast("官方线路要填 API key"); return; }
  if (base !== store.get(K.relayBase, "") || els.relayModel.value.trim() !== store.get(K.relayModel, "")) store.set("lumi.api.drop.relay", "[]");
  store.set(K.key, k);
  store.set(K.model, els.model.value);
  store.set(K.route, route);
  store.set(K.relayBase, base);
  store.set(K.relayKey, els.relayKey.value.trim());
  store.set(K.relayModel, els.relayModel.value.trim() || "claude-opus-5-5");
  store.set(K.relayVia, els.relayVia.checked ? "1" : "");
  els.sheet.hidden = true;
  paintStatus();
  toast("存好啦");
  if (!busy && conv[conv.length - 1]?.role === "timiya") run();
});

// iPhone 键盘弹出时按可见高度撑住
if (window.visualViewport) {
  const fit = () => { document.documentElement.style.setProperty("--app-h", `${Math.round(visualViewport.height)}px`); if (window.scrollY) window.scrollTo(0, 0); };
  visualViewport.addEventListener("resize", fit); fit();
}

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
render();
paintStatus();
sync().then(() => window.LumiMem?.sync(cfg())).then(paintStatus);
