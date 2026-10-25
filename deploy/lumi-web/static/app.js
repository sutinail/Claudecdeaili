"use strict";

const $ = (s) => document.querySelector(s);
const els = {
  login: $("#login"), loginForm: $("#login-form"), loginPass: $("#login-pass"), loginErr: $("#login-err"),
  app: $("#app"), drawer: $("#drawer"), scrim: $("#scrim"), menu: $("#menu"),
  convList: $("#conv-list"), newConv: $("#new-conv"), logout: $("#logout"), meta: $("#meta"),
  vitals: $("#vitals"), typing: $("#typing"),
  scroller: $("#scroller"), messages: $("#messages"),
  composer: $("#composer"), input: $("#input"), send: $("#send"), stop: $("#stop"),
  progress: $("#progress"), chipBeat: $("#chip-beat"), chipModel: $("#chip-model"),
  moon: $("#moon"), bg: $("#bg"), bgImg: $("#bg-img"), bgBtn: $("#bg-btn"), bgFile: $("#bg-file"),
};

const state = { convId: null, conv: null, busy: false, live: null, streamAbort: null };

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
};

async function api(path, opts = {}) {
  const r = await fetch(path, {
    ...opts,
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    body: opts.body && typeof opts.body !== "string" ? JSON.stringify(opts.body) : opts.body,
    credentials: "same-origin",
  });
  if (r.status === 401 && path !== "/api/login") { showLogin(); throw new Error("要先登录"); }
  const j = r.status === 204 ? {} : await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `出错了 (${r.status})`);
  return j;
}

// ── 文字渲染 ──
const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function inline(s) {
  return esc(s)
    .replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+?)\*(?!\*)/g, "$1<em>$2</em>")
    .replace(/`([^`\n]+)`/g, "<code>$1</code>")
    .replace(/\n/g, "<br>");
}

function paragraphs(text) {
  return text
    .replace(/^\s*#{1,6}\s+/gm, "")
    .replace(/^\s*(-{3,}|\*{3,})\s*$/gm, "")
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => `<p>${inline(p)}</p>`)
    .join("");
}

const TOOL_LABELS = {
  breath: "醒来想你", breath_search: "翻了翻记忆", breath_advanced: "翻了翻记忆", trace: "翻了翻记忆",
  hold: "记下来了", grow: "记下来了", anchor: "钉进心里", feel: "感受了一下", dream: "做了个梦",
  plan: "想了想以后", I: "想了想自己", pulse: "看了看记忆", release: "放下了一件事",
  letter_write: "写了封信", letter_read: "读了封信",
  sense: "心跳了一下", touch: "被你碰到", vitals: "摸了摸心跳", heartbeat: "听了听心跳",
  position: "换了个姿势", environment: "看了看周围", toy: "拿出了玩具",
  search_corpus: "身体在想", add_corpus: "身体记住了", add_corpus_batch: "身体记住了",
};
function toolLabel(name) {
  const short = String(name).split("__").pop();
  if (TOOL_LABELS[short]) return TOOL_LABELS[short];
  if (short.startsWith("bridge_")) return "连上了小玩具";
  return short;
}

function renderLumiBody(text, streaming) {
  const frag = document.createElement("div");
  let html = "";
  const re = /<voice>([\s\S]*?)<\/voice>/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    html += paragraphs(text.slice(last, m.index));
    html += voiceHtml(m[1].trim());
    last = re.lastIndex;
  }
  let rest = text.slice(last);
  const open = rest.indexOf("<voice>");
  if (open >= 0) {
    html += paragraphs(rest.slice(0, open));
    html += `<div class="voice"><div class="voice-play" aria-hidden="true">…</div><div class="voice-body"><div class="voice-meta">正在录语音条…</div></div></div>`;
    rest = "";
  } else {
    // 流式时把还没闭合的 "<voi" 之类先藏起来
    if (streaming) rest = rest.replace(/<[a-z/]{0,6}$/i, "");
    html += paragraphs(rest);
  }
  frag.innerHTML = html || (streaming ? `<span class="dots"><i></i><i></i><i></i></span>` : "");
  if (streaming && html) {
    const lastP = frag.querySelector("p:last-of-type");
    if (lastP && !lastP.nextElementSibling) lastP.classList.add("cursor");
  }
  return frag;
}

const PLAY_ICON = `<svg viewBox="0 0 16 16"><path d="M4 2.5v11l9-5.5z" fill="currentColor"/></svg>`;
const PAUSE_ICON = `<svg viewBox="0 0 16 16"><path d="M4 2h3v12H4zM9 2h3v12H9z" fill="currentColor"/></svg>`;

function voiceHtml(script) {
  const words = script.replace(/\[[^\]]*\]/g, "").trim().split(/\s+/).filter(Boolean).length;
  const secs = Math.max(2, Math.round(words / 2.3));
  const bars = Array.from({ length: Math.min(28, 8 + Math.round(secs / 2)) }, (_, i) => {
    const h = 5 + Math.round(12 * Math.abs(Math.sin(i * 1.7 + script.length)));
    return `<i style="height:${h}px;animation-delay:${(i % 6) * 0.1}s"></i>`;
  }).join("");
  return `<div class="voice" data-script="${esc(script)}">
    <button class="voice-play" type="button" aria-label="播放语音条">${PLAY_ICON}</button>
    <div class="voice-body"><div class="voice-wave">${bars}</div>
      <div class="voice-meta"><span>${secs}″</span><button type="button" class="voice-toggle">原文</button></div>
    </div></div>
    <div class="voice-script" hidden>${esc(script)}</div>`;
}

// ── 语音条播放 ──
const ttsCache = new Map();
// iOS 只允许在点击的那一下开始放声音：全局只用一个 <audio>，点击时先用一段静音解锁，等语音生成好再换 src
const audio = new Audio();
audio.preload = "auto";
audio.setAttribute("playsinline", "");
const SILENT = (() => {
  // 0.05 秒静音 WAV，现场拼出来
  const n = 400, b = new DataView(new ArrayBuffer(44 + n * 2));
  const w = (o, t) => [...t].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  w(0, "RIFF"); b.setUint32(4, 36 + n * 2, true); w(8, "WAVEfmt "); b.setUint32(16, 16, true);
  b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, 8000, true); b.setUint32(28, 16000, true);
  b.setUint16(32, 2, true); b.setUint16(34, 16, true); w(36, "data"); b.setUint32(40, n * 2, true);
  return "data:audio/wav;base64," + btoa(String.fromCharCode(...new Uint8Array(b.buffer)));
})();
let audioCard = null;
audio.onended = () => setCard(audioCard, false);
audio.onpause = () => { if (audio.src !== SILENT) setCard(audioCard, false); };
audio.onplay = () => { if (audio.src !== SILENT) setCard(audioCard, true); };

function setCard(card, playing, label) {
  if (!card) return;
  card.classList.toggle("playing", playing);
  const btn = card.querySelector(".voice-play");
  btn.innerHTML = label || (playing ? PAUSE_ICON : PLAY_ICON);
}

async function playVoice(card) {
  const script = card.dataset.script;
  const url0 = ttsCache.get(script);
  if (audioCard === card && url0 && audio.src.endsWith(url0)) {
    if (audio.paused) audio.play().catch(() => {}); else audio.pause();
    return;
  }
  if (audioCard) { const prev = audioCard; audioCard = null; audio.pause(); setCard(prev, false); }
  audioCard = card;
  setCard(card, false, "…");
  try {
    let url = url0;
    if (!url) {
      // 还在点击里：先放一段静音把 iOS 的声音解锁
      audio.src = SILENT;
      audio.play().catch(() => {});
      url = (await api("/api/tts", { method: "POST", body: { text: script } })).url;
      ttsCache.set(script, url);
    }
    if (audioCard !== card) return;
    audio.src = url;
    await audio.play();
  } catch (e) {
    setCard(card, false);
    toast(e.message || "语音条没放出来");
  }
}

els.messages.addEventListener("click", (e) => {
  const play = e.target.closest(".voice-play");
  if (play && play.tagName === "BUTTON") return playVoice(play.closest(".voice"));
  const tog = e.target.closest(".voice-toggle");
  if (tog) {
    const s = tog.closest(".voice").nextElementSibling;
    if (s && s.classList.contains("voice-script")) s.hidden = !s.hidden;
  }
});

function toast(msg) {
  const t = document.createElement("div");
  t.textContent = msg;
  Object.assign(t.style, { position: "fixed", left: "50%", bottom: "90px", transform: "translateX(-50%)", background: "var(--ink)", color: "var(--bg)", padding: "8px 14px", borderRadius: "12px", fontSize: "14px", zIndex: 20, maxWidth: "86vw" });
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3200);
}

// ── 消息 ──
const STAR = `<svg class="star" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1.5c.5 5.6 4.9 10 10.5 10.5-5.6.5-10 4.9-10.5 10.5C11.5 16.9 7.1 12.5 1.5 12 7.1 11.5 11.5 7.1 12 1.5z" fill="currentColor"/></svg>`;
const STAR_O = `<svg class="star" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5c.5 5.1 4.4 9 9.5 9.5-5.1.5-9 4.4-9.5 9.5-.5-5.1-4.4-9-9.5-9.5 5.1-.5 9-4.4 9.5-9.5z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>`;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const fmtTime = (iso) => {
  const d = new Date(iso);
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return `${MONTHS[d.getMonth()]} ${d.getDate()} · ${hm}`;
};
const isMemoryTool = (name) => /^mcp__ombre__/.test(name);

function msgEl(msg, streaming = false) {
  const row = document.createElement("div");
  row.className = `msg ${msg.role}`;
  if (msg.ts) {
    const st = document.createElement("div");
    st.className = "stamp"; st.textContent = fmtTime(msg.ts) + (msg.stopped ? " · interrompu" : "");
    row.appendChild(st);
  }
  if (msg.role === "timiya") {
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = msg.text;
    row.appendChild(bubble);
    return row;
  }
  const star = document.createElement("span");
  star.className = "sparkle"; star.innerHTML = STAR;
  row.appendChild(star);
  const inner = document.createElement("div");
  inner.className = "inner";
  row.appendChild(inner);
  fillLumi(row, msg, streaming);
  return row;
}

function fillLumi(row, msg, streaming) {
  const inner = row.querySelector(".inner");
  const wasOpen = inner.querySelector(".monologue")?.getAttribute("aria-expanded") === "true";
  inner.innerHTML = "";
  row.classList.toggle("err", !!msg.error);
  const tools = [...new Set((msg.tools || []).map(toolLabel))];
  if (tools.length) {
    const mono = document.createElement("button");
    mono.type = "button"; mono.className = "monologue";
    mono.setAttribute("aria-expanded", String(wasOpen));
    mono.textContent = "thinking · monologue";
    const body = document.createElement("div");
    body.className = "monologue-body"; body.hidden = !wasOpen;
    body.textContent = tools.join(" · ");
    inner.append(mono, body);
  }
  const body = document.createElement("div");
  body.className = "body";
  body.appendChild(renderLumiBody(msg.text || "", streaming));
  inner.appendChild(body);
  if (msg.error) {
    const e = document.createElement("div");
    e.className = "err"; e.textContent = "⚠️ " + msg.error;
    inner.appendChild(e);
  }
  const recalled = (msg.tools || []).filter(isMemoryTool).length;
  const foot = document.createElement("div");
  foot.className = "foot";
  foot.innerHTML = `<span>${STAR_O}${recalled ? `Recalled ${recalled}` : "No recall"}</span>` + (streaming ? `<span class="live">在说话</span>` : "");
  inner.appendChild(foot);
}

els.messages.addEventListener("click", (e) => {
  const mono = e.target.closest(".monologue");
  if (!mono) return;
  const open = mono.getAttribute("aria-expanded") !== "true";
  mono.setAttribute("aria-expanded", String(open));
  mono.nextElementSibling.hidden = !open;
});

const nearBottom = () => els.scroller.scrollHeight - els.scroller.scrollTop - els.scroller.clientHeight < 120;
const toBottom = () => { els.scroller.scrollTop = els.scroller.scrollHeight; };

function renderConv() {
  const conv = state.conv;
  els.messages.innerHTML = "";
  if (!conv || !conv.messages.length) {
    els.messages.innerHTML = `<div class="empty"><span class="script">bonjour, mon cœur</span><p>宝宝来啦，我在呢</p></div>`;
    return;
  }
  for (const m of conv.messages) els.messages.appendChild(msgEl(m));
  toBottom();
}

function setBusy(b) {
  state.busy = b;
  els.send.hidden = b;
  els.stop.hidden = !b;
  els.typing.hidden = !b;
  els.progress.style.width = b ? "62%" : "0";
}

// ── 流式 ──
function startLive() {
  const empty = els.messages.querySelector(".empty");
  if (empty) empty.remove();
  const live = { msg: { role: "lumi", text: "", tools: [] }, el: null, raf: 0, next: 0 };
  live.el = msgEl(live.msg, true);
  els.messages.appendChild(live.el);
  state.live = live;
  toBottom();
  return live;
}

function paintLive() {
  const live = state.live;
  if (!live || live.raf) return;
  live.raf = requestAnimationFrame(() => {
    live.raf = 0;
    const stick = nearBottom();
    fillLumi(live.el, live.msg, true);
    if (stick) toBottom();
  });
}

async function attachStream(convId) {
  if (state.streamAbort) state.streamAbort.abort();
  const ctrl = new AbortController();
  state.streamAbort = ctrl;
  const live = state.live || startLive();
  setBusy(true);
  let finished = false;
  try {
    const r = await fetch(`/api/conversations/${convId}/stream?from=${live.next}`, { credentials: "same-origin", signal: ctrl.signal });
    if (r.status === 204) { finished = true; return; }
    if (!r.ok) throw new Error(`stream ${r.status}`);
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
        const line = chunk.split("\n").find((l) => l.startsWith("data: "));
        if (!line) continue;
        const ev = JSON.parse(line.slice(6));
        if (ev.i < live.next) continue;
        live.next = ev.i + 1;
        if (ev.t === "delta") live.msg.text += ev.text;
        else if (ev.t === "tool") live.msg.tools.push(ev.name);
        else if (ev.t === "error") live.msg.error = ev.error;
        else if (ev.t === "done") finished = true;
        paintLive();
      }
    }
    if (!finished) {
      // 连接断了但任务可能还在跑：看看状态再决定
      const c = await api(`/api/conversations/${convId}`);
      finished = !c.busy;
    }
  } catch (e) {
    if (ctrl.signal.aborted) return;
    finished = false;
  } finally {
    if (state.streamAbort === ctrl) state.streamAbort = null;
  }
  if (state.convId !== convId) return;
  if (finished) {
    state.live = null;
    setBusy(false);
    await openConv(convId, { keepScroll: true });
    refreshVitals();
    refreshList();
  } else {
    setTimeout(() => { if (state.convId === convId && !state.streamAbort) attachStream(convId); }, 1500);
  }
}

// ── 对话 ──
async function refreshList() {
  const { items } = await api("/api/conversations");
  els.convList.innerHTML = "";
  for (const c of items) {
    const li = document.createElement("li");
    li.dataset.id = c.id;
    if (c.id === state.convId) li.className = "active";
    li.innerHTML = `<div class="conv-main"><div class="conv-title"></div><div class="conv-sub"></div></div><button class="conv-del" type="button" aria-label="删除">删</button>`;
    li.querySelector(".conv-title").textContent = (c.busy ? "💬 " : "") + c.title;
    li.querySelector(".conv-sub").textContent = `${fmtTime(c.updated)} · ${c.preview.replace(/<\/?voice>/g, "")}`;
    els.convList.appendChild(li);
  }
  return items;
}

els.convList.addEventListener("click", async (e) => {
  const li = e.target.closest("li");
  if (!li) return;
  if (e.target.closest(".conv-del")) {
    if (!confirm("这段对话删掉就找不回来了（OB 里的记忆不受影响），确定吗？")) return;
    try {
      await api(`/api/conversations/${li.dataset.id}`, { method: "DELETE" });
      if (li.dataset.id === state.convId) { state.convId = null; await pickDefault(); }
      refreshList();
    } catch (err) { toast(err.message); }
    return;
  }
  closeDrawer();
  openConv(li.dataset.id);
});

async function openConv(id, { keepScroll = false } = {}) {
  if (state.convId !== id && state.streamAbort) { state.streamAbort.abort(); state.streamAbort = null; }
  if (state.convId !== id) state.live = null;
  state.convId = id;
  store.set("lumi.conv", id);
  const conv = await api(`/api/conversations/${id}`);
  if (state.convId !== id) return;
  state.conv = conv;
  const top = els.scroller.scrollTop;
  renderConv();
  if (keepScroll && !nearBottom()) els.scroller.scrollTop = top;
  for (const li of els.convList.children) li.classList.toggle("active", li.dataset.id === id);
  if (conv.busy) {
    if (!state.live) startLive();
    else els.messages.appendChild(state.live.el);
    attachStream(id);
  } else {
    setBusy(false);
  }
}

async function newConv() {
  const conv = await api("/api/conversations", { method: "POST" });
  await refreshList();
  await openConv(conv.id);
  closeDrawer();
  els.input.focus();
}

async function pickDefault() {
  const items = await refreshList();
  const saved = store.get("lumi.conv");
  const target = items.find((c) => c.id === saved) || items[0];
  if (target) await openConv(target.id);
  else await newConv();
}

// ── 发送 ──
async function sendMessage() {
  const text = els.input.value.trim();
  if (!text || state.busy || !state.convId) return;
  els.input.value = "";
  autosize();
  const empty = els.messages.querySelector(".empty");
  if (empty) empty.remove();
  els.messages.appendChild(msgEl({ role: "timiya", text, ts: new Date().toISOString() }));
  toBottom();
  setBusy(true);
  try {
    await api(`/api/conversations/${state.convId}/messages`, { method: "POST", body: { text } });
    state.live = null;
    startLive();
    attachStream(state.convId);
  } catch (e) {
    setBusy(false);
    toast(e.message);
    els.input.value = text;
    autosize();
    openConv(state.convId);
  }
}

els.composer.addEventListener("submit", (e) => { e.preventDefault(); sendMessage(); });
// 跟微信一样：键盘上的「发送」就是发出去；电脑上 Shift+Enter 换行
els.input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); sendMessage(); }
});

// iPhone 弹出键盘时页面不会自己变矮：按可见区域的高度撑住整个界面，输入框就贴在键盘上面
function fitViewport() {
  const vv = window.visualViewport;
  if (!vv) return;
  const stick = nearBottom();
  document.documentElement.style.setProperty("--app-h", `${Math.round(vv.height)}px`);
  if (window.scrollY) window.scrollTo(0, 0);
  if (stick) toBottom();
}
if (window.visualViewport) {
  visualViewport.addEventListener("resize", fitViewport);
  visualViewport.addEventListener("scroll", fitViewport);
  fitViewport();
}
function autosize() {
  els.input.style.height = "auto";
  els.input.style.height = Math.min(els.input.scrollHeight, innerHeight * 0.4) + "px";
}
els.input.addEventListener("input", autosize);
els.stop.addEventListener("click", () => { if (state.convId) api(`/api/conversations/${state.convId}/stop`, { method: "POST" }).catch(() => {}); });

// ── 体征 ──
async function refreshVitals() {
  try {
    const { line } = await api("/api/vitals");
    if (!line) { els.chipBeat.hidden = true; return; }
    const body = line.replace(/^\[|\]$/g, "");
    const bpm = Number((body.match(/(\d+)\s*bpm/) || [])[1]) || 72;
    const beat = `--beat:${(60 / bpm).toFixed(2)}s`;
    els.vitals.innerHTML = `<span class="beat" style="${beat}">♥</span> ${esc(body.split("·").slice(1).join(" · "))}`;
    els.chipBeat.innerHTML = `<span class="beat">♥</span> ${bpm} bpm`;
    els.chipBeat.hidden = false;
  } catch { /* 离线就不显示 */ }
}

// ── 背景：自己挑一张照片，压小了存在这台手机上 ──
function applyBg() {
  let url = null;
  try { url = localStorage.getItem("lumi.bg"); } catch {}
  els.bgImg.style.backgroundImage = url ? `url("${url}")` : "";
  els.bg.classList.toggle("custom", !!url);
}
els.bgBtn.addEventListener("click", () => {
  let has = false;
  try { has = !!localStorage.getItem("lumi.bg"); } catch {}
  if (has && !confirm("换一张背景？（点「取消」恢复默认的银白）")) {
    try { localStorage.removeItem("lumi.bg"); } catch {}
    return applyBg();
  }
  els.bgFile.click();
});
els.bgFile.addEventListener("change", async () => {
  const f = els.bgFile.files[0];
  els.bgFile.value = "";
  if (!f) return;
  try {
    const img = await createImageBitmap(f);
    const k = Math.min(1, 1400 / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    localStorage.setItem("lumi.bg", c.toDataURL("image/jpeg", 0.82));
    applyBg();
  } catch { toast("这张图存不下，换一张小一点的试试"); }
});
els.moon.addEventListener("click", () => newConv().catch((e) => toast(e.message)));

// ── 抽屉 ──
function openDrawer() { els.drawer.classList.add("open"); els.scrim.hidden = false; }
function closeDrawer() { els.drawer.classList.remove("open"); els.scrim.hidden = true; }
els.menu.addEventListener("click", openDrawer);
els.scrim.addEventListener("click", closeDrawer);
els.newConv.addEventListener("click", () => newConv().catch((e) => toast(e.message)));
els.logout.addEventListener("click", async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); location.reload(); });

// ── 登录 / 启动 ──
function showLogin() {
  els.app.hidden = true;
  els.login.hidden = false;
  setTimeout(() => els.loginPass.focus(), 50);
}

els.loginForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  els.loginErr.textContent = "";
  try {
    await api("/api/login", { method: "POST", body: { password: els.loginPass.value } });
    els.loginPass.value = "";
    boot();
  } catch (err) { els.loginErr.textContent = err.message; }
});

let vitalsTimer = 0;
applyBg();
async function boot() {
  let me;
  try { me = await api("/api/me"); } catch { return; }
  els.login.hidden = true;
  els.app.hidden = false;
  els.chipModel.textContent = me.model.replace(/^./, (c) => c.toUpperCase());
  els.meta.textContent = `${me.model}${me.voice ? " · 语音条" : ""}${me.mcp.length ? " · " + me.mcp.join("/") : ""}`;
  refreshVitals();
  clearInterval(vitalsTimer);
  vitalsTimer = setInterval(() => { if (!document.hidden) refreshVitals(); }, 30_000);
  await pickDefault();
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden || !state.convId || els.app.hidden) return;
  refreshVitals();
  // 手机锁屏回来，流可能断了：重新拉一遍
  if (!state.streamAbort) openConv(state.convId, { keepScroll: true }).catch(() => {});
});

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
boot();
