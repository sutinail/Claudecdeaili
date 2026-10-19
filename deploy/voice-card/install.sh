#!/usr/bin/env bash
# 语音条（voice-card-mcp）一键部署 —— 跟 Ombre Brain 部署在同一台 VPS 上
#
# 单文件、自包含：服务端代码内嵌在脚本里，不需要访问 GitHub。
# 由 build.sh 从 install.template.sh + voice_card_mcp.py 生成 install.sh，别直接改 install.sh。
#
# 用法：sudo bash install.sh
#
# 可选环境变量：
#   VOICE_DIR       安装目录，默认 /opt/voice-card
#   VOICE_DOMAIN    公网域名，默认 voice.gpt1126.top
#   VOICE_PORT      宿主机端口，默认 18002（只绑 127.0.0.1）
#   VOICE_ID        ElevenLabs 音色，默认 Lumi（48uZMMvYcyyJiRxqFbxG）
#   CF_DIR          cloudflared 凭据目录，默认 /opt/ombre-brain/cloudflared（存在就自动把域名加进隧道）
#
# 重复运行是安全的：已有的 .env、授权状态和音频不会被覆盖。
set -euo pipefail

VOICE_DIR="${VOICE_DIR:-/opt/voice-card}"
VOICE_DOMAIN="${VOICE_DOMAIN:-voice.gpt1126.top}"
VOICE_PORT="${VOICE_PORT:-18002}"
VOICE_ID="${VOICE_ID:-48uZMMvYcyyJiRxqFbxG}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 合成一句话测试 ElevenLabs 是否可用
tts_test() {
  log "合成一句测试语音"
  $SUDO docker exec voice-card python -I -c \
    "import sys; sys.path.insert(0,'/app'); import voice_card_mcp as v; print(v.synthesize('Hey, Timiya. It is Lumi.'))"
}

# sudo bash install.sh --set-key：粘贴 ElevenLabs API Key（不回显、不进 shell 历史），写入 .env 并重启
if [ "${1:-}" = "--set-key" ]; then
  [ -f "$VOICE_DIR/.env" ] || die "还没装，先运行 sudo bash $0"
  printf '粘贴 ElevenLabs API Key 后回车（屏幕上不会显示）：'
  IFS= read -rs KEY; echo
  [ -n "$KEY" ] || die "没读到 Key"
  [ -z "$SUDO" ] || die "请用 sudo bash $0 --set-key 运行"
  KEY="$KEY" awk 'BEGIN{k=ENVIRON["KEY"]} /^ELEVENLABS_API_KEY=/{print "ELEVENLABS_API_KEY=" k; next} {print}' \
    "$VOICE_DIR/.env" > "$VOICE_DIR/.env.new"
  $SUDO chmod 600 "$VOICE_DIR/.env.new" && $SUDO mv "$VOICE_DIR/.env.new" "$VOICE_DIR/.env"
  unset KEY
  cd "$VOICE_DIR" && $SUDO docker compose up -d --force-recreate >/dev/null
  sleep 4
  tts_test
  exit 0
fi
if [ "${1:-}" = "--test" ]; then tts_test; exit 0; fi

command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1 \
  || die "没找到 docker compose。先跑 Ombre Brain 的 install.sh（它会装好 Docker），再跑这个。"

# 国内服务器 pip 走腾讯云镜像
PIP_INDEX="https://pypi.org/simple"
if ! curl -fsS -m 3 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
  PIP_INDEX="https://mirrors.cloud.tencent.com/pypi/simple"
fi

log "安装目录：$VOICE_DIR"
$SUDO mkdir -p "$VOICE_DIR/audio" "$VOICE_DIR/data"

# 1. 服务端代码
$SUDO tee "$VOICE_DIR/voice_card_mcp.py" >/dev/null <<'VOICE_PY_EOF'
#!/usr/bin/env python3
"""voice-card-mcp · 单文件版
===========================================================================
一个文件 = 一台完整的 MCP 服务器：把文字合成语音，渲染成微信风格的语音条卡片。
（卡片 HTML 也在这个文件里，往下翻到 VOICE_CARD_HTML。）
三步跑起来
    pip install "mcp>=1.9.0,<2" requests uvicorn
    export TTS_PROVIDER=elevenlabs ELEVENLABS_API_KEY=xxx ELEVENLABS_VOICE_ID=xxx
    export AUDIO_BASE_URL=https://你的域名/audio        # 必须公网 https，见下方说明
    python voice_card_mcp.py
然后在 claude.ai → 设置 → 连接器，填 https://你的域名/mcp，
Authorization 填 Bearer <MCP_AUTH_TOKEN>。
全部配置项都是环境变量，代码里没有任何真实密钥。
MIT License。致谢见文末 CREDITS。
===========================================================================
"""
from __future__ import annotations
import base64
import functools
import hashlib
import hmac
import json
import secrets
import inspect
import os
import sys
import time
import uuid
from urllib.parse import urlparse
import anyio
import requests
import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles
# ═══════════════════════════════════════════════════════════════════════
# 一、配置（全部来自环境变量）
# ═══════════════════════════════════════════════════════════════════════
TTS_PROVIDER = os.environ.get("TTS_PROVIDER", "elevenlabs").strip().lower()
ELEVENLABS_API_KEY = os.environ.get("ELEVENLABS_API_KEY", "")
ELEVENLABS_VOICE_ID = os.environ.get("ELEVENLABS_VOICE_ID", "")
ELEVENLABS_MODEL = os.environ.get("ELEVENLABS_MODEL", "eleven_multilingual_v2")
VOLCANO_APP_ID = os.environ.get("VOLCANO_APP_ID", "")
VOLCANO_ACCESS_TOKEN = os.environ.get("VOLCANO_ACCESS_TOKEN", "")
VOLCANO_VOICE_ID = os.environ.get("VOLCANO_VOICE_ID", "")
VOLCANO_CLUSTER = os.environ.get("VOLCANO_CLUSTER", "volcano_icl")
AUDIO_DIR = os.environ.get("AUDIO_DIR", "./public/audio")
# 🚨 全项目最容易配错的一项。要同时满足：
#    ① 公网可达（卡片跑在别人的网页里，localhost 它够不着）
#    ② https（宿主页面是 https，http 资源算混合内容，浏览器直接拦）
#    ③ 域名会被自动写进卡片的 CSP 白名单，填错就一定播不出声
AUDIO_BASE_URL = os.environ.get("AUDIO_BASE_URL", "http://127.0.0.1:8000/audio").rstrip("/")
AUDIO_KEEP_DAYS = int(os.environ.get("AUDIO_KEEP_DAYS", "7"))
HOST = os.environ.get("MCP_HOST", "0.0.0.0")
PORT = int(os.environ.get("MCP_PORT", "8000"))
AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN", "")
# 客户端不回传 mcp-session-id 时才开（症状：永远 "Missing session ID"）
STATELESS = os.environ.get("MCP_STATELESS", "0") == "1"
# OAuth（给 claude.ai 自定义连接器用：它只能填 URL，填不了请求头）。
# PUBLIC_URL 和 OAUTH_PASSWORD 都设置了才启用；启用后 MCP_AUTH_TOKEN 仍可当
# 静态 Bearer 用（给能填请求头的客户端）。
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
OAUTH_PASSWORD = os.environ.get("OAUTH_PASSWORD", "")
OAUTH_STATE_FILE = os.environ.get("OAUTH_STATE_FILE", "./data/oauth.json")
OAUTH_ACCESS_TTL = int(os.environ.get("OAUTH_ACCESS_TTL", str(30 * 86400)))
OAUTH_ENABLED = bool(PUBLIC_URL and OAUTH_PASSWORD)
_p = urlparse(AUDIO_BASE_URL)
ASSET_ORIGIN = f"{_p.scheme}://{_p.netloc}" if _p.netloc else ""
# ═══════════════════════════════════════════════════════════════════════
# 二、TTS：文字 → mp3 文件 → 公网 URL
# ═══════════════════════════════════════════════════════════════════════
def _save_mp3(audio_bytes: bytes, seed: str, prefix: str) -> str:
    os.makedirs(AUDIO_DIR, exist_ok=True)
    fname = f"{prefix}_{hashlib.md5(seed.encode()).hexdigest()[:12]}_{int(time.time())}.mp3"
    with open(os.path.join(AUDIO_DIR, fname), "wb") as f:
        f.write(audio_bytes)
    _cleanup()
    return f"{AUDIO_BASE_URL}/{fname}"
def _cleanup() -> None:
    """清掉过期生成物。只删自己的前缀——AUDIO_DIR 万一指到共用目录上，
    没这层判断就是一场事故。"""
    if AUDIO_KEEP_DAYS <= 0:
        return
    cutoff = time.time() - AUDIO_KEEP_DAYS * 86400
    try:
        for name in os.listdir(AUDIO_DIR):
            if not name.startswith(("el_", "vol_")):
                continue
            path = os.path.join(AUDIO_DIR, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    os.unlink(path)
            except OSError:
                pass
    except OSError:
        pass
def _tts_elevenlabs(text: str, voice_id: str = "") -> str:
    if not ELEVENLABS_API_KEY:
        return "ERROR: ELEVENLABS_API_KEY 未设置"
    vid = voice_id or ELEVENLABS_VOICE_ID
    if not vid:
        return "ERROR: ELEVENLABS_VOICE_ID 未设置"
    try:
        r = requests.post(
            f"https://api.elevenlabs.io/v1/text-to-speech/{vid}",
            headers={"xi-api-key": ELEVENLABS_API_KEY, "Content-Type": "application/json"},
            json={"text": text, "model_id": ELEVENLABS_MODEL,
                  "voice_settings": {"stability": 0.4, "similarity_boost": 0.75,
                                     "style": 0.4, "use_speaker_boost": True,
                                     "speed": 1.0}},
            timeout=60)
        if r.status_code == 429 or "quota_exceeded" in r.text:
            return "ERROR: ElevenLabs 额度用完了"
        if not r.ok:
            return f"FAIL {r.status_code}: {r.text[:200]}"
        return "OK: " + _save_mp3(r.content, text + vid, "el")
    except Exception as e:                                  # noqa: BLE001
        return f"ERROR: {e}"
def _tts_volcano(text: str, voice_id: str = "") -> str:
    if not VOLCANO_APP_ID or not VOLCANO_ACCESS_TOKEN:
        return "ERROR: VOLCANO_APP_ID / VOLCANO_ACCESS_TOKEN 未设置"
    vid = voice_id or VOLCANO_VOICE_ID
    if not vid:
        return "ERROR: VOLCANO_VOICE_ID 未设置"
    try:
        r = requests.post(
            "https://openspeech.bytedance.com/api/v1/tts",
            # ⚠️ 分号不是笔误：火山这个接口要 "Bearer;<token>"
            headers={"Authorization": f"Bearer;{VOLCANO_ACCESS_TOKEN}",
                     "Content-Type": "application/json"},
            json={"app": {"appid": VOLCANO_APP_ID, "token": VOLCANO_ACCESS_TOKEN,
                          "cluster": VOLCANO_CLUSTER},
                  "user": {"uid": "voice-card"},
                  "audio": {"voice_type": vid, "encoding": "mp3",
                            "rate": 24000, "speed_ratio": 1.0},
                  "request": {"reqid": str(uuid.uuid4()), "text": text,
                              "text_type": "plain", "operation": "query"}},
            timeout=60)
        if not r.ok:
            return f"FAIL {r.status_code}: {r.text[:200]}"
        data = r.json()
        if data.get("code") != 3000:                        # 3000 才是成功
            return f"TTS ERROR code={data.get('code')}: {data.get('message','')}"
        return "OK: " + _save_mp3(base64.b64decode(data["data"]), text + vid, "vol")
    except Exception as e:                                  # noqa: BLE001
        return f"ERROR: {e}"
def synthesize(text: str, voice_id: str = "", provider: str = "") -> str:
    """成功返回 "OK: <url>"，失败返回 ERROR/FAIL 开头的一行字。"""
    text = (text or "").strip()
    if not text:
        return "ERROR: text 不能为空"
    if len(text) > 2000:
        return "ERROR: text 太长了（>2000 字），分段合成吧"
    p = (provider or TTS_PROVIDER).lower()
    if p in ("volcano", "doubao", "bytedance"):
        return _tts_volcano(text, voice_id)
    return _tts_elevenlabs(text, voice_id)
# ═══════════════════════════════════════════════════════════════════════
# 三、卡片 HTML（整份内嵌在这里）
# ═══════════════════════════════════════════════════════════════════════
VOICE_CARD_HTML = r"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  /* ── 配色：亮色 / 暗色两套，跟随系统，也支持宿主用 data-theme 强制 ── */
  :root{
    --card1:#ffe3da; --card2:#f9c7ba; --edge:#f2b3a3; --ink:#7a3b2e;
    --btn1:#ffb3a0; --btn2:#f0876c; --rose:#e8836a; --sub:#b47c6c;
    --track:rgba(255,255,255,.55);
  }
  @media (prefers-color-scheme:dark){
    :root{--card1:#3d1f18;--card2:#2e1710;--edge:#5a2f24;--ink:#f6d0c4;
      --btn1:#c96b52;--btn2:#a3492f;--rose:#f0a58e;--sub:#c79a8c;--track:rgba(255,255,255,.15);}
  }
  :root[data-theme="dark"]{--card1:#3d1f18;--card2:#2e1710;--edge:#5a2f24;--ink:#f6d0c4;
    --btn1:#c96b52;--btn2:#a3492f;--rose:#f0a58e;--sub:#c79a8c;--track:rgba(255,255,255,.15);}
  :root[data-theme="light"]{--card1:#ffe3da;--card2:#f9c7ba;--edge:#f2b3a3;--ink:#7a3b2e;
    --btn1:#ffb3a0;--btn2:#f0876c;--rose:#e8836a;--sub:#b47c6c;--track:rgba(255,255,255,.55);}
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{overflow:hidden}                 /* 卡片在 iframe 里，绝不能出滚动条 */
  body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;
       background:transparent}               /* 透明背景，融进宿主的气泡 */
  .bar{display:flex;align-items:center;gap:13px;width:320px;max-width:100%;margin:0 auto;
    padding:12px 16px;border-radius:22px;overflow:hidden;
    background:linear-gradient(150deg,var(--card1),var(--card2));border:1px solid var(--edge);
    box-shadow:0 10px 26px rgba(180,90,60,.22),inset 0 1px 0 rgba(255,255,255,.4)}
  /* 播放按钮：CSS 三角形当"播放"，两根竖条当"暂停"，不用图标字体也不用图片 */
  .play{flex:none;width:46px;height:46px;border-radius:50%;border:0;cursor:pointer;position:relative;
    background:radial-gradient(120% 120% at 50% 30%,var(--btn1),var(--btn2));
    box-shadow:0 4px 10px rgba(180,90,60,.28);transition:transform .12s}
  .play:active{transform:scale(.92)}
  .play::before{content:"";position:absolute;top:50%;left:53%;transform:translate(-50%,-50%);
    width:0;height:0;border-left:15px solid #fff;border-top:9px solid transparent;border-bottom:9px solid transparent}
  .play.playing::before{border:0;width:13px;height:13px;left:50%;
    background:linear-gradient(90deg,#fff 0 34%,transparent 34% 66%,#fff 66%)}
  .mid{flex:1;min-width:0}
  .lab{font-size:13.5px;color:var(--ink);font-weight:700;letter-spacing:.2px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .wave{display:flex;align-items:center;gap:3px;height:20px;margin:7px 0 5px;cursor:pointer}
  .wave i{flex:1;background:var(--track);border-radius:2px;transition:background .1s;min-width:2px}
  .wave i.on{background:var(--rose)}
  .time{font-size:11px;color:var(--sub);font-variant-numeric:tabular-nums}
  .labRow{display:flex;align-items:center;gap:6px}
  .labRow .lab{flex:1}
  .dl{flex:none;width:19px;height:19px;border:0;border-radius:50%;cursor:pointer;
    background:var(--track);color:var(--ink);text-decoration:none;
    display:flex;align-items:center;justify-content:center;transition:transform .12s}
  .dl:active{transform:scale(.88)}
  .dl svg{width:11px;height:11px;display:block}
  .dl.open{background:var(--rose);color:#fff}
  /* 展开的链接行：沙箱拦下载时的兜底出口 */
  .urlRow{display:none;align-items:center;gap:5px;margin-top:6px}
  .urlRow.show{display:flex}
  .urlRow input{flex:1;min-width:0;font-size:10px;padding:3px 6px;border-radius:7px;
    border:1px solid var(--edge);background:var(--track);color:var(--ink);
    font-family:inherit;outline:none}
  .urlRow button{flex:none;font-size:10px;padding:3px 8px;border:0;border-radius:7px;
    cursor:pointer;background:var(--rose);color:#fff;font-family:inherit;white-space:nowrap}
  .urlRow button:active{transform:scale(.92)}
</style>
</head>
<body>
<div class="bar" id="bar">
  <button class="play" id="play" aria-label="播放"></button>
  <div class="mid">
    <div class="labRow">
      <div class="lab" id="lab">语音消息</div>
      <a class="dl" id="dl" aria-label="下载" title="保存到本地" target="_blank"
         rel="noopener" download><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/>
         <path d="m6 11 6 6 6-6"/><path d="M5 21h14"/></svg></a>
    </div>
    <div class="wave" id="wave"></div>
    <div class="time" id="time">0:00 / 0:00</div>
    <div class="urlRow" id="urlRow">
      <input id="urlIn" readonly aria-label="语音链接">
      <button id="cp" type="button">复制</button>
    </div>
  </div>
</div>
<!-- 降级用的 <audio>：Web Audio 不可用时才会被启用 -->
<audio id="au" preload="metadata" style="display:none"></audio>
<script>
/* ===========================================================================
 * 语音条卡片（MCP UI / ext-apps widget）
 *
 * 宿主（claude.ai / ChatGPT 等）把这个文件塞进一个沙箱 iframe，然后用
 * postMessage 把工具返回的 structuredContent 发进来。我们要做的事只有三件：
 *   1) 握手：告诉宿主"我准备好了"（ui/initialize + initialized）
 *   2) 收数据：监听 message，拿到 {audio, label, autoplay}
 *   3) 放声音：三档降级去播（见下面 loadAudio 的注释）
 *
 * ⚠️ 为什么不直接 <audio src="https://.../x.mp3"> ？
 *    沙箱 iframe 的 CSP 常把 media-src 掐死，跨域 mp3 直接赋给 <audio src>
 *    会静默失败（表现为"加载失败"、点了没反应）。而 connect-src（fetch）
 *    通常更宽松。所以正确姿势是：fetch 拿字节 → 本地播。
 * =========================================================================== */
var btn=document.getElementById("play"),lab=document.getElementById("lab"),
    wave=document.getElementById("wave"),timeEl=document.getElementById("time"),
    dlBtn=document.getElementById("dl"),au=document.getElementById("au");
var BARS=22,bars=[];
/* 静态"波形"：高低固定的一排竖条，播放进度点亮。
   真波形要解码后算 RMS，成本高、在小卡片上也看不出差别——这排装饰够用。 */
var HS=[9,14,7,17,11,20,8,15,10,18,6,13,16,9,19,12,7,15,10,14,8,17];
for(var i=0;i<BARS;i++){var b=document.createElement("i");
  b.style.height=HS[i%HS.length]+"px";wave.appendChild(b);bars.push(b);}
/* ── 播放状态机 ─────────────────────────────────────────────
   两种后端：
     mode="webaudio" → AudioContext + BufferSource（首选，完全不碰 media-src）
     mode="element"  → <audio> + blob: URL（降级）
   统一暴露 duration() / current() / startPlayback() / pausePlayback()      */
var mode="webaudio";
var audioCtx=null,audioBuffer=null,audioBytes=null,source=null;
var playing=false,startedAt=0,offset=0,raf=0,currentUrl="",stopping=false;
function fmt(s){s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+":"+("0"+(s%60)).slice(-2);}
function duration(){
  if(mode==="element")return isFinite(au.duration)?au.duration:0;
  return audioBuffer?audioBuffer.duration:0;
}
function current(){
  if(mode==="element")return au.currentTime||0;
  var c=playing&&audioCtx?offset+(audioCtx.currentTime-startedAt):offset,d=duration();
  return d?Math.min(c,d):c;
}
function paint(){
  var d=duration(),c=current(),p=d?c/d:0,lit=Math.round(p*BARS);
  for(var i=0;i<BARS;i++)bars[i].className=i<lit?"on":"";
  timeEl.textContent=fmt(c)+" / "+fmt(d);
  /* Web Audio 没有 timeupdate 事件，进度得自己用 rAF 推 */
  if(playing&&mode==="webaudio")raf=requestAnimationFrame(paint);
}
function stopSource(){if(source){stopping=true;try{source.stop();}catch(e){}source=null;}}
function finish(){playing=false;offset=0;source=null;btn.className="play";
  cancelAnimationFrame(raf);paint();}
/* 解码：decodeAudioData 不需要用户手势，所以拿到字节就先解，
   这样时长能立刻显示出来，而不是等第一次点播放。
   （只有 AudioContext.resume() 需要手势，那步留到点播放时做。）   */
function ensureDecoded(){
  if(audioBuffer)return Promise.resolve(audioBuffer);
  if(!audioBytes)return Promise.reject(new Error("audio not loaded"));
  var AC=window.AudioContext||window.webkitAudioContext;
  if(!AC)return Promise.reject(new Error("Web Audio unsupported"));
  if(!audioCtx)audioCtx=new AC();
  /* slice(0)：decodeAudioData 会"吃掉"(detach) 传进去的 ArrayBuffer，
     留个副本才能重复解码 */
  return audioCtx.decodeAudioData(audioBytes.slice(0)).then(function(buf){
    audioBuffer=buf;paint();return buf;
  });
}
function startPlayback(){
  if(mode==="element"){
    var pr=au.play();
    return (pr&&pr.then)?pr:Promise.resolve();
  }
  return ensureDecoded().then(function(){
    return audioCtx.resume();          /* 用户点了按钮，此时 resume 合法 */
  }).then(function(){
    stopSource();stopping=false;
    source=audioCtx.createBufferSource();
    source.buffer=audioBuffer;
    source.connect(audioCtx.destination);
    startedAt=audioCtx.currentTime;
    source.onended=function(){if(stopping){stopping=false;return;}finish();};
    source.start(0,Math.min(offset,Math.max(0,audioBuffer.duration-.01)));
    playing=true;btn.className="play playing";paint();
  });
}
function pausePlayback(){
  if(mode==="element"){au.pause();return;}
  if(!playing)return;
  offset=current();playing=false;btn.className="play";
  cancelAnimationFrame(raf);stopSource();paint();
}
btn.addEventListener("click",function(){
  if(playing){pausePlayback();return;}
  startPlayback().catch(function(e){
    lab.textContent="语音播放失败";btn.className="play";
    console.warn("[voice-card] play failed:",e);
  });
});
/* 点波形跳进度 */
wave.addEventListener("click",function(ev){
  var d=duration();if(!d)return;
  var r=wave.getBoundingClientRect(),p=Math.max(0,Math.min(1,(ev.clientX-r.left)/r.width));
  if(mode==="element"){au.currentTime=p*d;paint();return;}
  var was=playing;if(was)pausePlayback();
  offset=p*d;paint();
  if(was)startPlayback().catch(function(){lab.textContent="语音播放失败";});
});
/* <audio> 降级模式的事件（webaudio 模式下这些不会触发） */
au.addEventListener("play",function(){playing=true;btn.className="play playing";});
au.addEventListener("pause",function(){playing=false;btn.className="play";});
au.addEventListener("ended",function(){playing=false;btn.className="play";au.currentTime=0;paint();});
au.addEventListener("timeupdate",paint);
au.addEventListener("loadedmetadata",paint);
/* ── 下载：宿主 iframe 的 sandbox 决定了你能做什么 ──────────────
   实测四种组合（结论别靠猜，自己也可以复现）：
     sandbox                                    点下载的结果
     allow-scripts                              什么都不发生，连报错都没有
     + allow-popups                             开新标签页（不是下载）
     + allow-same-origin（无 downloads）         静默失败
     + allow-downloads                          才真的下载
   为什么两头堵：跨域时浏览器**忽略** download 属性，退化成普通导航，
   要 allow-popups；同源时 download 属性生效、走下载路径，要 allow-downloads。
   JS 造 blob + a.click() 更早就被拦，那条路根本不用试。
   所以这里做双保险：原生 <a> 的行为照留（宿主给了权限就正常开新标签），
   同时**就地把完整链接展开出来**，一键复制——粘到浏览器里打开谁都拦不住。 */
var urlRow=document.getElementById("urlRow"),urlIn=document.getElementById("urlIn"),
    cpBtn=document.getElementById("cp"),cpTimer=0;
dlBtn.addEventListener("click",function(ev){
  ev.stopPropagation();
  var href=dlBtn.getAttribute("href");
  if(!href){ev.preventDefault();return;}
  urlIn.value=href;
  urlRow.className=urlRow.className.indexOf("show")<0?"urlRow show":"urlRow";
  dlBtn.className=urlRow.className.indexOf("show")<0?"dl":"dl open";
  fit();                       /* 高度变了，重算一次，别出滚动条 */
  /* 故意不 preventDefault：宿主若允许弹窗，新标签页照开 */
});
function flash(msg){
  cpBtn.textContent=msg;
  clearTimeout(cpTimer);
  cpTimer=setTimeout(function(){cpBtn.textContent="复制";},1600);
}
cpBtn.addEventListener("click",function(ev){
  ev.stopPropagation();
  urlIn.focus();urlIn.select();
  try{urlIn.setSelectionRange(0,99999);}catch(e){}   /* iOS 要这句才真选中 */
  var ok=false;
  try{ok=document.execCommand("copy");}catch(e){}
  if(ok){flash("已复制");return;}
  /* execCommand 被禁时再试异步 API。它在 iframe 里常被 permissions policy
     拦掉，所以放第二位而不是第一位。 */
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(urlIn.value).then(
      function(){flash("已复制");},function(){flash("请长按复制");});
    return;
  }
  flash("请长按复制");
});
/* ── 取音频：三档降级 ─────────────────────────────────────────
   ① fetch → ArrayBuffer → Web Audio 解码播放   ← 首选，不碰 media-src
   ② fetch → blob: URL → <audio src>            ← Web Audio 不可用/解码失败
   ③ 直接把远程 URL 赋给 <audio src>            ← 连 fetch 都被拦时的最后一搏
   data: URI（base64 内嵌）走 ② 就够，不必 fetch。                        */
function loadAudio(url,autoplay){
  stopSource();playing=false;offset=0;audioBuffer=null;audioBytes=null;
  mode="webaudio";btn.className="play";paint();
  if(/^data:/i.test(url)){useElement(url,autoplay);return;}
  fetch(url).then(function(r){
    if(!r.ok)throw new Error("http "+r.status);
    return r.arrayBuffer();
  }).then(function(buf){
    audioBytes=buf;
    return ensureDecoded().then(function(){
      if(autoplay)startPlayback().catch(function(){});
    }).catch(function(e){
      /* 解码失败（编码不被支持 / 没有 Web Audio）→ 降级 ② */
      console.warn("[voice-card] decode failed, fallback to <audio>:",e);
      var blobUrl=URL.createObjectURL(new Blob([buf],{type:"audio/mpeg"}));
      useElement(blobUrl,autoplay);
    });
  }).catch(function(e){
    /* fetch 被 CSP/CORS 拦 → 降级 ③ 直连 */
    console.warn("[voice-card] fetch failed, fallback to direct src:",e);
    useElement(url,autoplay);
  });
}
function useElement(src,autoplay){
  mode="element";
  if(au.dataset.blobUrl){URL.revokeObjectURL(au.dataset.blobUrl);au.dataset.blobUrl="";}
  if(/^blob:/i.test(src))au.dataset.blobUrl=src;
  au.src=src;
  au.onerror=function(){lab.textContent="语音加载失败";};
  if(autoplay){var pr=au.play();if(pr&&pr.catch)pr.catch(function(){});}
  paint();
}
/* ── 渲染：把工具返回的 structuredContent 铺到界面上 ── */
function render(d){
  if(!d)return;
  if(d.label)lab.textContent=d.label;
  if(d.audio&&/^https?:/i.test(d.audio)){dlBtn.href=d.audio;dlBtn.style.display="";}
  else if(d.audio)dlBtn.style.display="none";     /* data: URI 没法当下载链接 */
  if(d.audio&&d.audio!==urlIn.value){             /* 换了新语音就收起旧链接 */
    urlRow.className="urlRow";dlBtn.className="dl";
  }
  if(d.audio&&d.audio!==currentUrl){
    currentUrl=d.audio;
    loadAudio(d.audio,!!d.autoplay);
  }
  if(d.error)lab.textContent="✗ "+d.error;
  fit();
}
/* 自适应：flex 条自己会伸缩，再按视口宽度整体缩放兜底，并把 body 高度
   贴着卡片高度设死——宿主按内容高度给 iframe 留位置，永不出滚动条。 */
function fit(){
  var c=document.getElementById("bar");
  c.style.transform="none";
  var vw=document.documentElement.clientWidth||320;
  var W=c.offsetWidth||320;
  var s=Math.min(1.15,Math.max(0.5,(vw-6)/W));
  c.style.transformOrigin="top center";
  c.style.transform="scale("+s+")";
  var h=Math.ceil(c.offsetHeight*s+8)+"px";
  document.body.style.height=h;
  document.documentElement.style.height=h;
}
window.addEventListener("resize",fit);
/* ── 跟宿主的 postMessage 契约 ──
   收：ui/notifications/tool-result 里的 params.structuredContent
       （有的宿主直接发 {structuredContent:...}，两种都接）
   发：ui/initialize（带 id，算一次请求）+ ui/notifications/initialized  */
window.addEventListener("message",function(ev){
  var msg=ev.data;if(!msg||typeof msg!=="object")return;
  if(msg.jsonrpc==="2.0"&&msg.method==="ui/notifications/tool-result")
    render(msg.params&&msg.params.structuredContent);
  if(msg.structuredContent)render(msg.structuredContent);
});
function send(method,params,id){
  var m={jsonrpc:"2.0",method:method,params:params||{}};
  if(id!==undefined)m.id=id;
  window.parent.postMessage(m,"*");
}
paint();fit();
window.addEventListener("load",fit);
setTimeout(fit,120);
send("ui/initialize",{name:"voice-card",version:"1.0.0"},1);
setTimeout(function(){send("ui/notifications/initialized",{});},50);
</script>
</body>
</html>
"""
# ═══════════════════════════════════════════════════════════════════════
# 四、MCP 服务器
# ═══════════════════════════════════════════════════════════════════════
# enable_dns_rebinding_protection=False：那层防护是给本地 localhost 场景的，
# 公网部署时它只会让所有外部 Host 吃 421 Invalid Host。真正的门是下面的 token。
# ── OAuth 授权服务器 ──
# 用 MCP SDK 自带的路由（/.well-known/*、/register、/authorize、/token、/revoke），
# 这里只实现存储和一个输密码的授权页。客户端、令牌落盘到 OAUTH_STATE_FILE，
# 重启不用重新授权；授权码和待确认的请求只放内存（几分钟就过期）。
from mcp.server.auth.provider import (AccessToken, AuthorizationCode,
                                      AuthorizationParams, RefreshToken,
                                      TokenError, construct_redirect_uri)
from mcp.server.auth.settings import (AuthSettings, ClientRegistrationOptions,
                                      RevocationOptions)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken


class VoiceOAuthProvider:
    def __init__(self, path: str):
        self.path = path
        self.clients: dict[str, dict] = {}
        self.access: dict[str, dict] = {}
        self.refresh: dict[str, dict] = {}
        self.codes: dict[str, AuthorizationCode] = {}
        self.pending: dict[str, tuple[str, AuthorizationParams, float]] = {}
        self._load()

    # ── 持久化 ──
    def _load(self) -> None:
        try:
            with open(self.path) as f:
                d = json.load(f)
            self.clients = d.get("clients", {})
            self.access = d.get("access", {})
            self.refresh = d.get("refresh", {})
        except FileNotFoundError:
            pass
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ 读取 {self.path} 失败，按空状态启动: {e}", flush=True)

    def _save(self) -> None:
        now = time.time()
        self.access = {k: v for k, v in self.access.items() if (v.get("expires_at") or now + 1) > now}
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"clients": self.clients, "access": self.access, "refresh": self.refresh}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    # ── 客户端注册（claude.ai 走动态注册）──
    async def get_client(self, client_id: str):
        c = self.clients.get(client_id)
        return OAuthClientInformationFull.model_validate(c) if c else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        self.clients[client_info.client_id] = client_info.model_dump(mode="json")
        self._save()

    # ── 授权：先跳到自己的密码页，密码对了再发授权码 ──
    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        now = time.time()
        self.pending = {k: v for k, v in self.pending.items() if v[2] > now}
        req = secrets.token_urlsafe(24)
        self.pending[req] = (client.client_id, params, now + 600)
        return f"{PUBLIC_URL}/login?req={req}"

    def approve(self, req: str) -> str | None:
        item = self.pending.pop(req, None)
        if not item or item[2] < time.time():
            return None
        client_id, params, _ = item
        code = secrets.token_urlsafe(32)
        self.codes[code] = AuthorizationCode(
            code=code, scopes=params.scopes or [], expires_at=time.time() + 300,
            client_id=client_id, code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource)
        return construct_redirect_uri(str(params.redirect_uri), code=code, state=params.state)

    def pending_ok(self, req: str) -> bool:
        item = self.pending.get(req)
        return bool(item and item[2] > time.time())

    async def load_authorization_code(self, client, authorization_code: str):
        c = self.codes.get(authorization_code)
        if c and c.client_id == client.client_id and c.expires_at > time.time():
            return c
        return None

    def _issue(self, client_id: str, scopes: list[str], resource: str | None) -> OAuthToken:
        at, rt = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        exp = int(time.time()) + OAUTH_ACCESS_TTL
        self.access[at] = {"client_id": client_id, "scopes": scopes, "expires_at": exp, "resource": resource}
        self.refresh[rt] = {"client_id": client_id, "scopes": scopes, "resource": resource}
        self._save()
        return OAuthToken(access_token=at, expires_in=OAUTH_ACCESS_TTL,
                          scope=" ".join(scopes) or None, refresh_token=rt)

    async def exchange_authorization_code(self, client, authorization_code: AuthorizationCode) -> OAuthToken:
        if self.codes.pop(authorization_code.code, None) is None:
            raise TokenError("invalid_grant", "authorization code already used")
        return self._issue(client.client_id, authorization_code.scopes, authorization_code.resource)

    async def load_refresh_token(self, client, refresh_token: str):
        r = self.refresh.get(refresh_token)
        if r and r["client_id"] == client.client_id:
            return RefreshToken(token=refresh_token, client_id=r["client_id"],
                                scopes=r["scopes"], resource=r.get("resource"))
        return None

    async def exchange_refresh_token(self, client, refresh_token: RefreshToken, scopes: list[str]) -> OAuthToken:
        self.refresh.pop(refresh_token.token, None)  # 轮换：旧的作废
        return self._issue(client.client_id, scopes or refresh_token.scopes, refresh_token.resource)

    async def load_access_token(self, token: str):
        if AUTH_TOKEN and hmac.compare_digest(token, AUTH_TOKEN):
            return AccessToken(token=token, client_id="static-token", scopes=[])
        a = self.access.get(token)
        if not a or (a.get("expires_at") and a["expires_at"] < time.time()):
            return None
        return AccessToken(token=token, client_id=a["client_id"], scopes=a["scopes"],
                           expires_at=a.get("expires_at"), resource=a.get("resource"))

    async def revoke_token(self, token) -> None:
        t = token.token
        cid = token.client_id
        self.access.pop(t, None)
        self.refresh.pop(t, None)
        # 同一客户端的另一半也一并作废
        for store in (self.access, self.refresh):
            for k in [k for k, v in store.items() if v["client_id"] == cid]:
                store.pop(k, None)
        self._save()


oauth = VoiceOAuthProvider(OAUTH_STATE_FILE) if OAUTH_ENABLED else None
_auth_kwargs = {}
if oauth:
    _auth_kwargs = dict(
        auth_server_provider=oauth,
        auth=AuthSettings(
            issuer_url=PUBLIC_URL,
            resource_server_url=f"{PUBLIC_URL}/mcp",
            validate_token_resource=False,
            client_registration_options=ClientRegistrationOptions(enabled=True),
            revocation_options=RevocationOptions(enabled=True)))

mcp = FastMCP("voice-card", stateless_http=STATELESS,
              transport_security=TransportSecuritySettings(
                  enable_dns_rebinding_protection=False),
              **_auth_kwargs)
# ── 补丁一：同步工具丢线程池 ──
# FastMCP 对同步函数是直接在事件循环主线程上跑。TTS 要等几秒网络 IO，
# 这几秒整台服务器对所有请求装聋——连 tools/list 都超时，
# 表现成"工具明明在，却调不动"。
_tool_orig = mcp.tool
def _tool_nonblocking(*d_args, **d_kwargs):
    deco = _tool_orig(*d_args, **d_kwargs)
    def wrap(fn):
        if inspect.iscoroutinefunction(fn):
            return deco(fn)
        @functools.wraps(fn)                # 保住签名，inputSchema 才不受影响
        async def async_fn(*args, **kwargs):
            return await anyio.to_thread.run_sync(functools.partial(fn, *args, **kwargs))
        return deco(async_fn)
    return wrap
mcp.tool = _tool_nonblocking
# ── 补丁二：声明 UI 扩展能力 ──
# 宿主要在 initialize 的 capabilities.experimental 里看到这个 key，
# 才认这台服务器能给 HTML 卡片。SDK 还没有正式 API，只能打补丁。
try:
    _orig_opts = mcp._mcp_server.create_initialization_options
    def _patched_opts():
        opts = _orig_opts()
        try:
            cap = opts.capabilities
            exp = cap.experimental if cap.experimental is not None else {}
            exp["io.modelcontextprotocol/ui"] = {}
            try:
                cap.experimental = exp
            except Exception:                       # pydantic 冻结模型的退路
                opts.capabilities = cap.model_copy(update={"experimental": exp})
        except Exception:
            pass
        return opts
    mcp._mcp_server.create_initialization_options = _patched_opts
except Exception as e:                              # noqa: BLE001
    print(f"⚠️  UI capability 声明失败（卡片可能不渲染）: {e}", flush=True)
# ── 卡片的 CSP 白名单 ──
# 卡片跑在宿主的沙箱 iframe 里，默认 CSP 会拦掉它对外的 fetch。
# 这里显式声明"我要连这个域名"，宿主才会放行。两套字段都写：
#   ui.csp.*           → MCP UI / claude.ai
#   openai/widgetCSP.* → OpenAI Apps SDK（下划线命名，别写错）
#
# 🚨 千万不要加 "domain" / "openai/widgetDomain"。那会让宿主拿它当卡片自己的
#    沙箱源，一旦跟实际不符，所有卡片直接 "Failed to load the MCP app"。
WIDGET_META = {
    "ui": {"csp": {"resourceDomains": [ASSET_ORIGIN] if ASSET_ORIGIN else [],
                   "connectDomains": [ASSET_ORIGIN] if ASSET_ORIGIN else []}},
    "openai/widgetCSP": {"resource_domains": [ASSET_ORIGIN] if ASSET_ORIGIN else [],
                         "connect_domains": [ASSET_ORIGIN] if ASSET_ORIGIN else []},
}
# mime_type 里的 ;profile=mcp-app 是关键，宿主靠它认出"这是个卡片"。
# 💡 改了 HTML 宿主还在渲染旧版？连接器按 URI 缓存卡片壳子。办法是升一个
#    版本号 URI，**同时保留旧 URI 做别名**返回同一份 HTML。
@mcp.resource("ui://voice-card-v1", mime_type="text/html;profile=mcp-app", meta=WIDGET_META)
def voice_card_ui() -> str:
    return VOICE_CARD_HTML
@mcp.resource("ui://voice-card", mime_type="text/html;profile=mcp-app", meta=WIDGET_META)
def voice_card_ui_legacy() -> str:
    return VOICE_CARD_HTML
# structured_output=True 必须有：返回的 dict 才会进 structuredContent，
# 卡片就是从那里拿数据的。
@mcp.tool(meta={"ui/resourceUri": "ui://voice-card-v1",
                "ui": {"resourceUri": "ui://voice-card-v1"}},
          structured_output=True)
def voice_card(text: str, voice_id: str = "", label: str = "",
               provider: str = "", autoplay: bool = False) -> dict[str, str]:
    """把一句话合成语音，渲染成可播放的语音条卡片。
    text: 要念的文字
    voice_id: 指定音色，留空用环境变量里的默认音色
    label: 卡片标题，留空自动取文字开头
    provider: elevenlabs / volcano，留空用 TTS_PROVIDER
    autoplay: True 则卡片加载完自动播一次
    """
    r = synthesize(text, voice_id, provider)
    if not r.startswith("OK: "):
        return {"error": r[:160], "label": label or "合成失败"}
    # 🚨 只回 URL，绝不把 base64 音频塞进返回值：5 万+ 字符的响应体会把
    #    宿主的卡片加载器直接搞崩（"Failed to load the MCP app"）。
    #    音频由卡片自己 fetch，响应体永远保持轻量。
    return {"audio": r[4:].strip(),
            "label": label or (text[:18] + ("…" if len(text) > 18 else "")),
            "autoplay": "1" if autoplay else ""}
@mcp.tool()
def voice_url(text: str, voice_id: str = "", provider: str = "") -> str:
    """只合成语音、返回 mp3 链接，不渲染卡片（给不支持 HTML 卡片的客户端）。"""
    return synthesize(text, voice_id, provider)
# ── 鉴权：最朴素的 Bearer token 门 ──
class AuthMiddleware:
    """/audio 和 /healthz 免鉴权（音频必须让卡片匿名 fetch，否则播不出来），
    其余一律要 Authorization: Bearer <MCP_AUTH_TOKEN>。
    token 留空 = 完全裸奔，只适合本机调试。"""
    OPEN_PREFIXES = ("/audio", "/healthz")
    def __init__(self, app):
        self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not AUTH_TOKEN:
            return await self.app(scope, receive, send)
        if scope.get("path", "").startswith(self.OPEN_PREFIXES):
            return await self.app(scope, receive, send)
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        if headers.get("authorization", "") == f"Bearer {AUTH_TOKEN}":
            return await self.app(scope, receive, send)
        await send({"type": "http.response.start", "status": 401,
                    "headers": [(b"content-type", b"application/json")]})
        await send({"type": "http.response.body", "body": b'{"error":"unauthorized"}'})
LOGIN_HTML = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>授权语音条</title>
<style>body{font-family:-apple-system,"PingFang SC",sans-serif;background:#fbefea;color:#7a3b2e;
display:grid;place-items:center;min-height:100vh;margin:0;padding:16px;box-sizing:border-box}
form{background:#fff;border-radius:18px;padding:24px;width:min(100%,340px);box-shadow:0 10px 26px rgba(180,90,60,.18)}
h1{font-size:18px;margin:0 0 6px}p{font-size:13px;color:#b47c6c;margin:0 0 16px}
input{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid #f2b3a3;border-radius:10px;font-size:15px}
button{margin-top:12px;width:100%;padding:11px;border:0;border-radius:10px;background:#f0876c;color:#fff;font-size:15px}
.err{color:#c0392b;font-size:13px;margin-top:10px}</style></head><body>
<form method="post"><h1>授权 Claude 使用语音条</h1><p>输入语音条服务的密码（OAUTH_PASSWORD）</p>
<input type="hidden" name="req" value="{req}"><input type="password" name="password" autofocus required>
<button type="submit">授权</button>{err}</form></body></html>"""


def _login_page(req: str, err: str = "", status: int = 200) -> HTMLResponse:
    import html as _h
    body = LOGIN_HTML.replace("{req}", _h.escape(req)).replace(
        "{err}", f'<div class="err">{_h.escape(err)}</div>' if err else "")
    return HTMLResponse(body, status_code=status)


async def login(request: Request):
    if not oauth:
        return JSONResponse({"error": "oauth disabled"}, status_code=404)
    if request.method == "GET":
        req = request.query_params.get("req", "")
        if not oauth.pending_ok(req):
            return _login_page("", "授权请求已过期，请回到 Claude 重新连接。", 400)
        return _login_page(req)
    form = await request.form()
    req, pw = str(form.get("req", "")), str(form.get("password", ""))
    if not oauth.pending_ok(req):
        return _login_page("", "授权请求已过期，请回到 Claude 重新连接。", 400)
    if not hmac.compare_digest(pw.encode(), OAUTH_PASSWORD.encode()):
        await anyio.sleep(1.5)  # 放慢暴力猜密码
        return _login_page(req, "密码不对，再试一次。", 401)
    target = oauth.approve(req)
    if not target:
        return _login_page("", "授权请求已过期，请回到 Claude 重新连接。", 400)
    return RedirectResponse(target, status_code=302)


async def healthz(request: Request):
    return JSONResponse({"ok": True, "provider": TTS_PROVIDER, "asset_origin": ASSET_ORIGIN,
                         "oauth": OAUTH_ENABLED})
def main():
    os.makedirs(AUDIO_DIR, exist_ok=True)
    if not AUTH_TOKEN and not OAUTH_ENABLED:
        print("⚠️  MCP_AUTH_TOKEN 未设置：谁拿到地址都能调你的工具、烧你的 TTS 额度。", flush=True)
    if not ASSET_ORIGIN:
        print("⚠️  AUDIO_BASE_URL 解析不出域名，CSP 白名单是空的，卡片取不到音频。", flush=True)
    elif ASSET_ORIGIN.startswith("http://") and "127.0.0.1" not in ASSET_ORIGIN \
            and "localhost" not in ASSET_ORIGIN:
        print("⚠️  AUDIO_BASE_URL 是 http://：宿主页面是 https，混合内容会被浏览器拦。", flush=True)
    app = mcp.streamable_http_app()
    # 插到路由表最前面：streamable app 自带顶层 lifespan（会话管理器住在里面），
    # 重新 Mount 进一个新的 Starlette 会把那个 lifespan 丢掉，服务直接起不来。
    app.router.routes.insert(0, Route("/healthz", endpoint=healthz))
    app.router.routes.insert(0, Mount("/audio", app=StaticFiles(directory=AUDIO_DIR),
                                      name="audio"))
    print(f"🔊 voice-card-mcp → http://{HOST}:{PORT}/mcp", flush=True)
    print(f"   TTS provider = {TTS_PROVIDER}", flush=True)
    print(f"   audio        = {AUDIO_DIR}  →  {AUDIO_BASE_URL}", flush=True)
    if oauth:
        app.router.routes.insert(0, Route("/login", endpoint=login, methods=["GET", "POST"]))
        print(f"   oauth        = on  → issuer {PUBLIC_URL}", flush=True)
        # OAuth 模式下 /mcp 由 SDK 的 RequireAuthMiddleware 把关（OAuth 令牌或静态 token 都认），
        # /audio、/healthz、/login 和 OAuth 端点保持公开。
        uvicorn.run(app, host=HOST, port=PORT)
    else:
        uvicorn.run(AuthMiddleware(app), host=HOST, port=PORT)
if __name__ == "__main__":
    sys.exit(main())
# ═══════════════════════════════════════════════════════════════════════
# CREDITS
#   · 语音条形态（微信风格播放条 + ext-apps 内嵌卡片）与「卡片必须显式声明
#     CSP resourceDomains / connectDomains」这个关键发现，参考自
#     garan0613/voice-mcp（MIT）https://github.com/garan0613/voice-mcp
#     ——那是一份 TypeScript / Cloudflare Workers / MiniMax 的实现；
#     本文件是独立重写的 Python / FastMCP / ElevenLabs·火山 版本。
#   · MCP 协议与 Python SDK：modelcontextprotocol（MIT）
#   · widgetCSP 字段命名沿用 OpenAI Apps SDK 的约定，以便一份卡片两边都能用。
# ═══════════════════════════════════════════════════════════════════════
VOICE_PY_EOF

# 2. Dockerfile + compose
$SUDO tee "$VOICE_DIR/Dockerfile" >/dev/null <<DOCKERFILE
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir -i $PIP_INDEX "mcp>=1.9.0,<2" requests uvicorn
COPY voice_card_mcp.py /app/voice_card_mcp.py
ENV AUDIO_DIR=/app/audio OAUTH_STATE_FILE=/app/data/oauth.json MCP_HOST=0.0.0.0 MCP_PORT=8000 PYTHONUNBUFFERED=1
CMD ["python", "-I", "/app/voice_card_mcp.py"]
DOCKERFILE

$SUDO tee "$VOICE_DIR/docker-compose.yml" >/dev/null <<'YML'
services:
  voice-card:
    build: .
    image: voice-card:local
    container_name: voice-card
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${VOICE_PORT:-18002}:8000"
    volumes:
      - ./audio:/app/audio
      - ./data:/app/data
YML

# 3. .env（只在第一次生成）
ENV_FILE="$VOICE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机授权密码和静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# 语音条配置 —— 含密钥，不要提交到 git、不要截图外传
VOICE_PORT=$VOICE_PORT
TTS_PROVIDER=elevenlabs
# 去 ElevenLabs 后台建一个只开 Text to Speech 权限、设了额度上限的 API Key，填在这里
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=$VOICE_ID
ELEVENLABS_MODEL=eleven_multilingual_v2
# 公网地址：OAuth 授权和音频链接都用它
PUBLIC_URL=https://$VOICE_DOMAIN
AUDIO_BASE_URL=https://$VOICE_DOMAIN/audio
AUDIO_KEEP_DAYS=7
# claude.ai 添加连接器时，授权页要输入的密码
OAUTH_PASSWORD=$(rand 20)
# 给能填请求头的客户端用：Authorization: Bearer <MCP_AUTH_TOKEN>
MCP_AUTH_TOKEN=$(rand 40)
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 构建并启动
log "构建镜像并启动（第一次要下载 Python 镜像和依赖，稍等）"
cd "$VOICE_DIR"
$SUDO docker compose up -d --build

log "等待服务就绪（http://127.0.0.1:$VOICE_PORT/healthz）"
ok=""
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$VOICE_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { $SUDO docker compose logs --tail 40; die "服务没起来，上面是日志"; }
log "语音条服务已启动 ✅"

# 5. 把域名加进 Ombre Brain 那条 Cloudflare 隧道
if [ -d "$CF_DIR" ] && [ -f "$CF_DIR/cert.pem" ]; then
  TID="$($SUDO ls "$CF_DIR" | grep -E '^[0-9a-f-]{36}\.json$' | head -1 | sed 's/\.json$//')"
  if [ -n "$TID" ]; then
    log "把 $VOICE_DOMAIN 加进隧道 $TID"
    CF="$SUDO docker run --rm -v $CF_DIR:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"
    $CF tunnel route dns "$TID" "$VOICE_DOMAIN" || log "（DNS 记录可能已存在，继续）"
    # 只增不删：已有 config.yml 就把本域名插进去，不动别的服务（比如耳朵）的条目
    CFG="$CF_DIR/config.yml"
    if ! $SUDO test -f "$CFG"; then
      OMBRE_HOST="$(grep -h '^  public_url:' /opt/ombre-brain/buckets/config.yaml 2>/dev/null | sed -E 's#.*https://([^"/]+).*#\1#' | head -1)"
      $SUDO tee "$CFG" >/dev/null <<CFGEOF
tunnel: $TID
credentials-file: /home/nonroot/.cloudflared/$TID.json
ingress:
  - hostname: ${OMBRE_HOST:-ombre.gpt1126.top}
    service: http://localhost:18001
  - service: http_status:404
CFGEOF
    fi
    if ! $SUDO grep -q "hostname: $VOICE_DOMAIN\$" "$CFG"; then
      $SUDO awk -v h="$VOICE_DOMAIN" -v p="$VOICE_PORT" \
        '/^  - service: http_status:404/ && !d {print "  - hostname: " h; print "    service: http://localhost:" p; d=1} {print}' \
        "$CFG" | $SUDO tee "$CFG.new" >/dev/null
      $SUDO mv "$CFG.new" "$CFG"
    fi
    $SUDO chown 65532:65532 "$CFG"
    $SUDO docker rm -f cloudflared >/dev/null 2>&1 || true
    $SUDO docker run -d --name cloudflared --restart unless-stopped --network host \
      -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest \
      tunnel --no-autoupdate --protocol http2 --config /home/nonroot/.cloudflared/config.yml run "$TID" >/dev/null
    log "隧道现在转发：$($SUDO grep -h 'hostname:' "$CFG" | awk '{print $3}' | paste -sd' ')"
  fi
else
  log "没找到 $CF_DIR/cert.pem，跳过隧道配置（需要自己把 $VOICE_DOMAIN 指到 127.0.0.1:$VOICE_PORT）"
fi

echo
if ! $SUDO grep -qE '^ELEVENLABS_API_KEY=.+' "$ENV_FILE"; then
  echo "下一步：填 ElevenLabs API Key（命令会让你粘贴，屏幕上不显示）："
  echo "  sudo bash $0 --set-key"
fi
echo "授权密码（添加连接器时用，看完别截图）：sudo grep OAUTH_PASSWORD $ENV_FILE"
echo "连接器地址：https://$VOICE_DOMAIN/mcp"
