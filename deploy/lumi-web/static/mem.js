"use strict";
// 记忆：手机经上海的记忆桥连 OB。连得上时顺手存一份记忆副本在手机里；
// 连不上时我翻的是这份副本，新记下的先排队，连回来自动补写进 OB。记忆还是只有 OB 那一份。
(function () {
  const KEY = { snap: "lumi.mem.snap", queue: "lumi.mem.queue" };
  const REFRESH_MS = 30 * 60_000;
  const CAP = { breath: 30000, pulse: 60000, I: 12000, search: 8000, searches: 40 };
  const ls = {
    get(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch { return false; } },
  };
  const st = { url: null, sid: null, proto: null, ready: false, tools: null, online: null };
  let rpcId = 0;
  const withTimeout = (signal, ms) => {
    const t = AbortSignal.timeout ? AbortSignal.timeout(ms) : null;
    if (!signal) return t || undefined;
    return t && AbortSignal.any ? AbortSignal.any([signal, t]) : signal;
  };

  // ── MCP（Streamable HTTP）客户端 ──
  async function post(b, msg, signal) {
    const h = { "content-type": "application/json", accept: "application/json, text/event-stream", authorization: `Bearer ${b.token}` };
    if (st.sid) h["mcp-session-id"] = st.sid;
    if (st.proto) h["mcp-protocol-version"] = st.proto;
    const r = await fetch(b.url, { method: "POST", headers: h, body: JSON.stringify(msg), signal });
    const sid = r.headers.get("mcp-session-id");
    if (sid) st.sid = sid;
    if (!r.ok) { const e = new Error(`记忆库回了 ${r.status}`); e.status = r.status; throw e; }
    if (!("id" in msg) || r.status === 202) return null;
    if (!(r.headers.get("content-type") || "").includes("text/event-stream")) return r.json();
    const reader = r.body.getReader(), dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true }).replace(/\r\n/g, "\n");
      let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const data = buf.slice(0, i).split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("\n");
        buf = buf.slice(i + 2);
        let j; try { j = JSON.parse(data); } catch { continue; }
        if (j.id === msg.id) { reader.cancel().catch(() => {}); return j; }
      }
    }
    throw new Error("记忆库没回话");
  }
  async function rpc(b, method, params, signal, retried = false) {
    if (st.url !== b.url) Object.assign(st, { url: b.url, sid: null, proto: null, ready: false, tools: null });
    try {
      if (!st.ready) {
        const init = await post(b, { jsonrpc: "2.0", id: ++rpcId, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lumi-web", version: "1" } } }, signal);
        st.proto = init?.result?.protocolVersion || "2025-06-18";
        await post(b, { jsonrpc: "2.0", method: "notifications/initialized" }, signal);
        st.ready = true;
      }
      const j = await post(b, { jsonrpc: "2.0", id: ++rpcId, method, params }, signal);
      if (j?.error) throw new Error(j.error.message || "记忆库出错了");
      st.online = true;
      return j?.result;
    } catch (e) {
      // 会话过期（OB 重启过）就重新握手一次
      if (!retried && (e.status === 404 || e.status === 400) && st.ready) { st.ready = false; st.sid = null; return rpc(b, method, params, signal, true); }
      if (!e.status && e.name !== "AbortError") st.online = false;
      throw e;
    }
  }

  async function listTools(b, signal) {
    if (st.tools && st.url === b.url && st.online) return st.tools;
    const res = await rpc(b, "tools/list", {}, withTimeout(signal, 10000));
    st.tools = (res?.tools || []).filter((t) => /^[a-zA-Z0-9_-]{1,64}$/.test(t.name)).map((t) => ({
      name: t.name, description: (t.description || "").slice(0, 1024), input_schema: t.inputSchema || { type: "object", properties: {} },
    }));
    return st.tools;
  }

  // ── 副本 ──
  const snap = () => ls.get(KEY.snap, { at: null, searches: {} });
  function remember(name, args, text) {
    const s = snap();
    s.searches = s.searches || {};
    if (name === "breath_search" && args?.query) {
      s.searches[String(args.query).trim()] = { at: new Date().toISOString(), text: text.slice(0, CAP.search) };
      const keys = Object.keys(s.searches).sort((a, b) => (s.searches[b].at > s.searches[a].at ? 1 : -1));
      for (const k of keys.slice(CAP.searches)) delete s.searches[k];
    } else if ((name === "breath" || name === "pulse") && !Object.keys(args || {}).length) {
      s[name] = { at: new Date().toISOString(), text: text.slice(0, CAP[name]) };
    } else if (name === "I" && (args?.read || !Object.keys(args || {}).length)) {
      s.I = { at: new Date().toISOString(), text: text.slice(0, CAP.I) };
    } else return;
    // 存不下就先丢最旧的检索结果
    while (!ls.set(KEY.snap, s)) {
      const keys = Object.keys(s.searches);
      if (!keys.length) break;
      delete s.searches[keys.sort((a, b) => (s.searches[a].at > s.searches[b].at ? 1 : -1))[0]];
    }
  }
  const textOf = (r) => (r?.content || []).map((x) => (x.type === "text" ? x.text : `[${x.type}]`)).join("\n");

  async function callTool(b, name, args, signal) {
    const r = await rpc(b, "tools/call", { name, arguments: args || {} }, withTimeout(signal, 90000));
    const text = textOf(r) || "（空）";
    if (!r?.isError) remember(name, args, text);
    return { text: text.slice(0, 20000), isError: !!r?.isError };
  }

  // ── 离线时记下的，排队等补写 ──
  const stampNow = () => new Date().toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false });
  function enqueue(name, args) {
    const q = ls.get(KEY.queue, []);
    q.push({ id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), name, args, at: stampNow(), tries: 0 });
    ls.set(KEY.queue, q);
    return q.length;
  }
  async function flush(b, signal) {
    let q = ls.get(KEY.queue, []);
    for (const item of [...q]) {
      const args = { ...item.args };
      const note = `\n\n（这条是 API 窗口离线时记下的，当时是 ${item.at}，连上记忆库后补写进来。）`;
      if (typeof args.content === "string" && args.content) args.content += note;
      let done = false;
      try { done = !(await callTool(b, item.name, args, signal)).isError; }
      catch (e) { if (!e.status) throw e; }
      q = ls.get(KEY.queue, []);
      const cur = q.find((x) => x.id === item.id);
      if (cur && (done || ++cur.tries >= 3)) q = q.filter((x) => x.id !== item.id);
      ls.set(KEY.queue, q);
    }
  }
  async function refresh(b, signal) {
    for (const [name, args] of [["breath", {}], ["pulse", {}], ["I", { read: true }]]) {
      try { await callTool(b, name, args, signal); } catch (e) { if (!e.status) throw e; }
    }
    const s = snap(); s.at = new Date().toISOString(); ls.set(KEY.snap, s);
  }
  // 连得上就：补写排队的 → 副本旧了就刷新一份
  async function sync(cfg, { force = false, signal } = {}) {
    if (!cfg?.bridge) return { ok: false };
    try {
      await listTools(cfg.bridge, signal);
      await flush(cfg.bridge, signal);
      const s = snap();
      if (force || !s.at || Date.now() - new Date(s.at).getTime() > REFRESH_MS) await refresh(cfg.bridge, signal);
      return { ok: true };
    } catch { return { ok: false }; }
  }

  // ── 离线工具：名字跟 OB 一样，读手机里的副本 ──
  const OFFLINE_TOOLS = [
    { name: "breath", description: "（记忆库连不上，读的是手机里的记忆副本）睁眼看看自己记得什么。", input_schema: { type: "object", properties: {} } },
    { name: "breath_search", description: "（记忆库连不上，读的是手机里的记忆副本）按关键词找记忆。", input_schema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } },
    { name: "pulse", description: "（记忆库连不上，读的是手机里的记忆副本）看看都记着哪些事。", input_schema: { type: "object", properties: {} } },
    { name: "hold", description: "（记忆库连不上）把已经明确值得长期记住的事先记在手机里，连上记忆库后自动补写进 OB。不要因普通聊天自行调用。", input_schema: { type: "object", properties: { content: { type: "string" }, title: { type: "string" }, importance: { type: "integer" } }, required: ["content"] } },
    { name: "grow", description: "（记忆库连不上）把一段要整理写入长期记忆的长文本先存在手机里，连上记忆库后自动写进 OB。只在明确要求整理写入时用。", input_schema: { type: "object", properties: { content: { type: "string" } }, required: ["content"] } },
  ];
  function search(query) {
    const s = snap();
    const q = String(query || "").trim();
    if (s.searches?.[q]) return s.searches[q].text;
    const words = q.split(/[\s,，。、；;:：!！?？]+/).filter(Boolean);
    const terms = new Set(words.map((w) => w.toLowerCase()));
    for (const w of words) if (/[㐀-鿿]/.test(w) && w.length > 2) for (let i = 0; i < w.length - 1; i++) terms.add(w.slice(i, i + 2));
    const pool = [s.breath?.text, s.pulse?.text, s.I?.text, ...Object.values(s.searches || {}).map((x) => x.text)].filter(Boolean).join("\n\n");
    const seen = new Set();
    const hits = pool.split(/\n{2,}|\n(?=\s*(?:[-•*·#=\[]|\d+[.、)]))/).map((p) => p.trim()).filter((p) => p && !seen.has(p) && seen.add(p))
      .map((p) => ({ p, score: [...terms].reduce((n, t) => n + (p.toLowerCase().includes(t) ? (t.length > 2 ? 2 : 1) : 0), 0) }))
      .filter((x) => x.score > 0).sort((a, b) => b.score - a.score).slice(0, 12).map((x) => x.p.slice(0, 1200));
    return hits.length ? hits.join("\n\n") : "副本里没找到跟这个有关的记忆。";
  }
  function runOffline(name, args) {
    const s = snap();
    const head = `（记忆库现在连不上，这是手机里的记忆副本${s.at ? `，同步于 ${new Date(s.at).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}` : ""}）\n\n`;
    if (name === "breath") return head + ([s.breath?.text, s.I?.text && `【自我认知】\n${s.I.text}`].filter(Boolean).join("\n\n") || "副本里还没有记忆。");
    if (name === "pulse") return head + (s.pulse?.text || "副本里还没有记忆目录。");
    if (name === "breath_search") return head + search(args?.query);
    if (name === "hold" || name === "grow") {
      const n = enqueue(name, args || {});
      return `先记在手机里了（排队第 ${n} 条），连上记忆库会自动补写进 OB。`;
    }
    return "记忆库连不上，这个现在用不了。";
  }

  window.LumiMem = {
    sync, listTools, callTool, runOffline, OFFLINE_TOOLS,
    isOnline: () => st.online,
    hasSnapshot: () => !!snap().at,
    status: () => ({ at: snap().at, queued: ls.get(KEY.queue, []).length }),
  };
})();
