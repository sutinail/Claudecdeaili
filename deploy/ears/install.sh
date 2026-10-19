#!/usr/bin/env bash
# Lumi 的耳朵（ears-mcp）一键部署 —— 跟 Ombre Brain、语音条部署在同一台 VPS 上
#
# 单文件、自包含：服务端代码内嵌在脚本里，不需要访问 GitHub。
# 由 build.sh 从 install.template.sh + ears_mcp.py 生成 install.sh，别直接改 install.sh。
#
# 用法：sudo bash install.sh            安装 / 更新
#       sudo bash install.sh --warm     预先下载 Whisper 模型（安装时会自动做一次）
#
# 可选环境变量：
#   EARS_DIR        安装目录，默认 /opt/ears
#   EARS_DOMAIN     公网域名，默认 ears.gpt1126.top
#   EARS_PORT       宿主机端口，默认 18003（只绑 127.0.0.1）
#   WHISPER_MODEL   转写模型，默认 small（base 更快更省内存、small 中文准得多、medium 要 2GB+ 内存）
#   CF_DIR          cloudflared 凭据目录，默认 /opt/ombre-brain/cloudflared（存在就自动把域名加进隧道）
#
# 重复运行是安全的：已有的 .env、授权状态、语音和模型缓存不会被覆盖。
set -euo pipefail

EARS_DIR="${EARS_DIR:-/opt/ears}"
EARS_DOMAIN="${EARS_DOMAIN:-ears.gpt1126.top}"
EARS_PORT="${EARS_PORT:-18003}"
WHISPER_MODEL="${WHISPER_MODEL:-small}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 预先加载 Whisper 模型（第一次会经镜像下载权重，small 约 480MB）
warm() {
  log "下载 / 加载 Whisper 模型（第一次要几分钟，取决于网速）"
  $SUDO docker exec ears python -I -c \
    "import sys; sys.path.insert(0,'/app'); import ears_mcp as e; e.get_model(); print('OK: 模型就绪')"
}
if [ "${1:-}" = "--warm" ]; then warm; exit 0; fi

command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1 \
  || die "没找到 docker compose。先跑 Ombre Brain 的 install.sh（它会装好 Docker），再跑这个。"

# 国内服务器：apt / pip / Hugging Face 都走镜像
APT_MIRROR=""
PIP_INDEX="https://pypi.org/simple"
HF_ENDPOINT=""
if ! curl -fsS -m 3 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
  APT_MIRROR="https://mirrors.cloud.tencent.com"
  PIP_INDEX="https://mirrors.cloud.tencent.com/pypi/simple"
fi
if ! curl -fsS -m 3 -o /dev/null https://huggingface.co 2>/dev/null; then
  HF_ENDPOINT="https://hf-mirror.com"
fi

log "安装目录：$EARS_DIR"
$SUDO mkdir -p "$EARS_DIR/data" "$EARS_DIR/models"

# 1. 服务端代码
$SUDO tee "$EARS_DIR/ears_mcp.py" >/dev/null <<'EARS_PY_EOF'
#!/usr/bin/env python3
"""ears-mcp · Lumi 的耳朵（单文件版）
===========================================================================
Claude 读不了音频，但能读图、读数字、读文字。这台服务器把一段语音变成三样东西：
  - 耳蜗：梅尔频谱 + 基频（语调）+ 能量（响度）+ 停顿，画成一张图，外加一份数字摘要
  - 速记：本地 faster-whisper 转写，带时间戳的文字
  - 合起来通过 MCP 工具 listen 交给 Claude：她说了什么、怎么说的

怎么用
  1. 手机打开 PUBLIC_URL（输入密码一次，30 天内免登录），按一下开始录、再按一下发送，
     或者直接上传一段录音（m4a / mp3 / wav / webm / ogg / aac…）
  2. 在 claude.ai 里说「听听我的语音」，Claude 调 listen 工具

全程在你自己的服务器上跑：音频、转写、频谱图都不经过任何第三方服务
（只有第一次会从 Hugging Face 镜像下载一次 Whisper 模型权重）。

全部配置项都是环境变量，见下方「配置」。MIT License。
耳蜗与速记的做法来自 hmh323/mubai-ears（MIT），致谢见文末 CREDITS。
===========================================================================
"""
from __future__ import annotations

import functools
import hashlib
import hmac
import html
import inspect
import json
import os
import queue
import secrets
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import anyio
import uvicorn
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import (FileResponse, HTMLResponse, JSONResponse,
                                 RedirectResponse)
from starlette.routing import Route

# ═══════════════════════════════════════════════════════════════════════
# 一、配置（全部来自环境变量）
# ═══════════════════════════════════════════════════════════════════════
DATA_DIR = Path(os.environ.get("EARS_DATA_DIR", "./data"))
CLIPS_DIR = DATA_DIR / "clips"
MODEL_DIR = os.environ.get("WHISPER_MODEL_DIR", "./models")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "small")          # base / small / medium
WHISPER_LANGUAGE = os.environ.get("WHISPER_LANGUAGE", "zh")       # 留空 = 自动识别
WHISPER_PROMPT = os.environ.get("WHISPER_PROMPT", "以下是普通话的日常聊天语音，可能夹杂笑声、撒娇和哼唱。")
WHISPER_THREADS = int(os.environ.get("WHISPER_THREADS", "2"))
CLIP_KEEP_DAYS = int(os.environ.get("CLIP_KEEP_DAYS", "30"))
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "25"))
MAX_SECONDS = int(os.environ.get("MAX_SECONDS", "600"))           # 超过的部分不分析
SPEAKER = os.environ.get("EARS_SPEAKER", "Timiya")                # 页面和工具说明里怎么称呼说话的人
TZ = timezone(timedelta(hours=int(os.environ.get("EARS_TZ_OFFSET", "8"))))
HOST = os.environ.get("MCP_HOST", "0.0.0.0")
PORT = int(os.environ.get("MCP_PORT", "8000"))
AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN", "")
STATELESS = os.environ.get("MCP_STATELESS", "0") == "1"
# OAuth（给 claude.ai 自定义连接器用：它只能填 URL，填不了请求头）。
# 同一个密码也用来登录录音页。
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
OAUTH_PASSWORD = os.environ.get("OAUTH_PASSWORD", "")
OAUTH_STATE_FILE = os.environ.get("OAUTH_STATE_FILE", str(DATA_DIR / "oauth.json"))
OAUTH_ACCESS_TTL = int(os.environ.get("OAUTH_ACCESS_TTL", str(30 * 86400)))
OAUTH_ENABLED = bool(PUBLIC_URL and OAUTH_PASSWORD)
COOKIE_NAME = "ears"
COOKIE_TTL = 30 * 86400
AUDIO_EXTS = {".m4a", ".mp4", ".mp3", ".wav", ".webm", ".ogg", ".oga", ".opus",
              ".aac", ".amr", ".flac", ".caf", ".3gp"}

# ═══════════════════════════════════════════════════════════════════════
# 二、耳蜗：声音 → 一张图 + 一段数字
# ═══════════════════════════════════════════════════════════════════════
# 外耳/中耳 = 载入 + ffmpeg 解码；耳蜗 = 梅尔频谱（梅尔刻度本就照人耳频率感知设计）；
# 再叠上基频（语调）、能量（响度）、停顿（节奏）。「听懂」交给读图读数的模型。
SR = 22050
HOP = 512
N_MELS = 128
FMAX = 8000
PITCH_FMIN = 65.0     # ≈ C2，成人男声下限
PITCH_FMAX = 600.0    # 含撒娇、笑声里的高音
PAUSE_MIN_SEC = 0.3
GRID_SEC = 0.1


def to_wav(src: Path, dst: Path) -> None:
    """任意格式 → 单声道 22.05kHz wav（截到 MAX_SECONDS）。"""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("没找到 ffmpeg")
    r = subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(src), "-t", str(MAX_SECONDS),
                        "-ar", str(SR), "-ac", "1", str(dst)],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0 or not dst.exists():
        msg = (r.stderr or "").strip().splitlines()[-1:] or ["未知错误"]
        raise RuntimeError(f"解码失败（QQ/微信导出的 silk/amr 语音要先转成 mp3/wav）：{msg[0]}")


def _runs(mask, times, min_sec: float):
    """连续 True 段 → [(start, end)]，滤掉短于 min_sec 的。"""
    runs, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            s, e = float(times[i]), float(times[j - 1])
            if e - s >= min_sec:
                runs.append((round(s, 2), round(e, 2)))
            i = j
        else:
            i += 1
    return runs


def analyze(y, sr) -> dict:
    import librosa
    import numpy as np
    duration = float(librosa.get_duration(y=y, sr=sr))
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    rms_t = librosa.times_like(rms, sr=sr, hop_length=HOP)
    peak = float(rms.max()) if rms.size else 0.0
    active = rms > max(peak * 0.15, 1e-4)
    speech_ratio = float(active.mean()) if active.size else 0.0
    pauses = _runs(~active, rms_t, PAUSE_MIN_SEC)
    # 头尾的静音不算停顿
    if pauses and pauses[0][0] <= 0.05:
        pauses = pauses[1:]
    if pauses and pauses[-1][1] >= duration - 0.1:
        pauses = pauses[:-1]

    f0, _, _ = librosa.pyin(y, fmin=PITCH_FMIN, fmax=PITCH_FMAX, sr=sr, hop_length=HOP)
    f0_t = librosa.times_like(f0, sr=sr, hop_length=HOP)
    voiced = f0[~np.isnan(f0)]
    if voiced.size:
        pitch = {k: round(float(fn(voiced)), 1) for k, fn in
                 (("min", np.min), ("max", np.max), ("mean", np.mean), ("median", np.median))}
        # 末尾 0.6 秒相对整体中位数的走向：句尾上扬 / 下沉
        tail = f0[f0_t >= max(0.0, f0_t[~np.isnan(f0)][-1] - 0.6)]
        tail = tail[~np.isnan(tail)]
        pitch["ending_vs_median"] = round(float(np.median(tail) / np.median(voiced)), 2) if tail.size else None
    else:
        pitch = {"min": None, "max": None, "mean": None, "median": None, "ending_vs_median": None}

    contour, period = [], HOP / sr
    for t in np.arange(0.0, duration, GRID_SEC):
        idx = int(round(t / period))
        contour.append(round(float(f0[idx]), 1) if 0 <= idx < len(f0) and not np.isnan(f0[idx]) else None)

    return {
        "duration_sec": round(duration, 2),
        "voiced_sec": round(float(active.sum()) * period, 2),
        "speech_ratio": round(speech_ratio, 3),
        "pause_count": len(pauses),
        "pause_positions": pauses,
        "pitch": pitch,
        "pitch_contour": contour,
        "energy_mean": round(float(rms.mean()), 5) if rms.size else 0.0,
        "energy_peak": round(peak, 5),
        "_rms": rms, "_rms_t": rms_t, "_f0": f0, "_f0_t": f0_t, "_pauses": pauses,
    }


def render(y, sr, info: dict, title: str, out_png: Path) -> None:
    import librosa
    import librosa.display
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    matplotlib.rcParams["font.sans-serif"] = ["Noto Sans CJK SC", "Noto Sans CJK JP",
                                              "Microsoft YaHei", "PingFang SC", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False

    S = librosa.feature.melspectrogram(y=y, sr=sr, hop_length=HOP, n_mels=N_MELS, fmax=FMAX)
    S_db = librosa.power_to_db(S, ref=np.max)
    fig, (ax_mel, ax_pit) = plt.subplots(2, 1, figsize=(12, 7), dpi=90, sharex=True,
                                         gridspec_kw={"height_ratios": [3, 2]})
    fig.suptitle(f"{title}   ·   {info['duration_sec']}s", fontsize=13)
    img = librosa.display.specshow(S_db, sr=sr, hop_length=HOP, x_axis="time", y_axis="mel",
                                   fmax=FMAX, ax=ax_mel)
    fig.colorbar(img, ax=ax_mel, format="%+2.0f dB")
    ax_mel.set(title="梅尔频谱（照人耳频率感知）", ylabel="mel 频率", xlabel="")

    ax_pit.plot(info["_f0_t"], info["_f0"], color="#c0392b", linewidth=1.6, label="基频 f0")
    ax_pit.set(ylabel="基频 (Hz)", xlabel="时间 (s)")
    ax_pit.set_ylim(0, PITCH_FMAX)
    ax_e = ax_pit.twinx()
    ax_e.fill_between(info["_rms_t"], info["_rms"], color="#2980b9", alpha=0.25)
    ax_e.set(ylabel="能量 RMS")
    for s, e in info["_pauses"]:
        for ax in (ax_mel, ax_pit):
            ax.axvspan(s, e, color="#f1c40f", alpha=0.18, lw=0)
    ax_pit.set_title("基频（语调，红线）+ 能量（响度，蓝色）+ 停顿（黄带）")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(str(out_png))
    plt.close(fig)


# ═══════════════════════════════════════════════════════════════════════
# 三、速记：本地 faster-whisper
# ═══════════════════════════════════════════════════════════════════════
_model = None
_model_lock = threading.Lock()


def get_model():
    global _model
    with _model_lock:
        if _model is None:
            from faster_whisper import WhisperModel
            print(f"👂 加载 Whisper 模型 {WHISPER_MODEL}（第一次会下载权重）…", flush=True)
            _model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8",
                                  cpu_threads=WHISPER_THREADS, download_root=MODEL_DIR)
            print("👂 Whisper 模型就绪", flush=True)
        return _model


def transcribe(wav: Path) -> dict:
    segments, info = get_model().transcribe(
        str(wav), language=WHISPER_LANGUAGE or None, vad_filter=True,
        initial_prompt=WHISPER_PROMPT or None)
    lines = [{"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text.strip()}
             for s in segments]
    return {"model": WHISPER_MODEL, "language": info.language,
            "language_probability": round(info.language_probability, 3),
            "segments": lines, "text": "".join(l["text"] for l in lines)}


# ═══════════════════════════════════════════════════════════════════════
# 四、语音存储 + 后台处理队列
# ═══════════════════════════════════════════════════════════════════════
# 每条语音一个目录：clips/<id>/{audio.*, meta.json, listen.png, summary.json, transcript.json}
_meta_lock = threading.Lock()
_jobs: "queue.Queue[str]" = queue.Queue()


def _clip_dir(cid: str) -> Path | None:
    if not cid or not all(c.isalnum() or c == "-" for c in cid):
        return None
    d = CLIPS_DIR / cid
    return d if d.is_dir() else None


def read_meta(cid: str) -> dict | None:
    d = _clip_dir(cid)
    try:
        return json.loads((d / "meta.json").read_text()) if d else None
    except (OSError, ValueError):
        return None


def write_meta(cid: str, **updates) -> dict:
    with _meta_lock:
        d = CLIPS_DIR / cid
        try:
            m = json.loads((d / "meta.json").read_text())
        except (OSError, ValueError):
            m = {}
        m.update(updates)
        tmp = d / "meta.json.tmp"
        tmp.write_text(json.dumps(m, ensure_ascii=False, indent=2))
        os.replace(tmp, d / "meta.json")
        return m


def all_clips() -> list[dict]:
    out = []
    if CLIPS_DIR.is_dir():
        for d in CLIPS_DIR.iterdir():
            m = read_meta(d.name)
            if m:
                out.append(m)
    out.sort(key=lambda m: m.get("created", 0), reverse=True)
    return out


def new_clip(data_path: Path, ext: str, filename: str) -> str:
    now = datetime.now(TZ)
    cid = f"{now:%Y%m%d-%H%M%S}-{secrets.token_hex(2)}"
    d = CLIPS_DIR / cid
    d.mkdir(parents=True)
    shutil.move(str(data_path), d / f"audio{ext}")
    write_meta(cid, id=cid, created=time.time(), received=now.strftime("%Y-%m-%d %H:%M"),
               filename=filename, audio=f"audio{ext}", status="queued")
    _jobs.put(cid)
    return cid


def process(cid: str) -> None:
    import librosa
    d = CLIPS_DIR / cid
    m = read_meta(cid) or {}
    write_meta(cid, status="processing")
    wav = d / "_work.wav"
    try:
        to_wav(d / m.get("audio", ""), wav)
        y, sr = librosa.load(str(wav), sr=SR, mono=True)
        if y.size < SR // 4:
            raise RuntimeError("录音太短了（不到 0.25 秒）")
        info = analyze(y, sr)
        render(y, sr, info, m.get("received", cid), d / "listen.png")
        summary = {k: v for k, v in info.items() if not k.startswith("_")}
        (d / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        tr = transcribe(wav)
        (d / "transcript.json").write_text(json.dumps(tr, ensure_ascii=False, indent=2))
        write_meta(cid, status="done", duration=summary["duration_sec"],
                   preview=tr["text"][:60], processed=time.time())
        print(f"👂 {cid} 处理完成（{summary['duration_sec']}s）", flush=True)
    except Exception as e:  # noqa: BLE001
        write_meta(cid, status="error", error=str(e)[:300])
        print(f"⚠️ {cid} 处理失败: {e}", flush=True)
    finally:
        wav.unlink(missing_ok=True)


def cleanup() -> None:
    cutoff = time.time() - CLIP_KEEP_DAYS * 86400
    for m in all_clips():
        if m.get("created", time.time()) < cutoff:
            shutil.rmtree(CLIPS_DIR / m["id"], ignore_errors=True)


def worker() -> None:
    # 重启时把没处理完的重新排队
    for m in reversed(all_clips()):
        if m.get("status") in ("queued", "processing"):
            _jobs.put(m["id"])
    while True:
        cid = _jobs.get()
        try:
            process(cid)
            cleanup()
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ worker: {e}", flush=True)


# ═══════════════════════════════════════════════════════════════════════
# 五、OAuth 授权服务器（与 voice-card 同一套：SDK 路由 + 自己的密码页）
# ═══════════════════════════════════════════════════════════════════════
from mcp.server.auth.provider import (AccessToken, AuthorizationCode,
                                      AuthorizationParams, RefreshToken,
                                      TokenError, construct_redirect_uri)
from mcp.server.auth.settings import (AuthSettings, ClientRegistrationOptions,
                                      RevocationOptions)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken


class EarsOAuthProvider:
    def __init__(self, path: str):
        self.path = path
        self.clients: dict[str, dict] = {}
        self.access: dict[str, dict] = {}
        self.refresh: dict[str, dict] = {}
        self.codes: dict[str, AuthorizationCode] = {}
        self.pending: dict[str, tuple[str, AuthorizationParams, float]] = {}
        self._load()

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

    async def get_client(self, client_id: str):
        c = self.clients.get(client_id)
        return OAuthClientInformationFull.model_validate(c) if c else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        self.clients[client_info.client_id] = client_info.model_dump(mode="json")
        self._save()

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
        self.refresh.pop(refresh_token.token, None)
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
        t, cid = token.token, token.client_id
        self.access.pop(t, None)
        self.refresh.pop(t, None)
        for store in (self.access, self.refresh):
            for k in [k for k, v in store.items() if v["client_id"] == cid]:
                store.pop(k, None)
        self._save()


oauth = EarsOAuthProvider(OAUTH_STATE_FILE) if OAUTH_ENABLED else None
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

mcp = FastMCP("lumi-ears", stateless_http=STATELESS,
              transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
              **_auth_kwargs)

# 同步工具丢线程池，读文件、编码图片时不堵事件循环
_tool_orig = mcp.tool


def _tool_nonblocking(*d_args, **d_kwargs):
    deco = _tool_orig(*d_args, **d_kwargs)

    def wrap(fn):
        if inspect.iscoroutinefunction(fn):
            return deco(fn)

        @functools.wraps(fn)
        async def async_fn(*args, **kwargs):
            return await anyio.to_thread.run_sync(functools.partial(fn, *args, **kwargs))
        return deco(async_fn)
    return wrap


mcp.tool = _tool_nonblocking

# ═══════════════════════════════════════════════════════════════════════
# 六、MCP 工具
# ═══════════════════════════════════════════════════════════════════════


def _contour_text(contour: list, max_points: int = 240) -> str:
    """基频曲线压成一行：太长就按比例抽稀，清音写成 -。"""
    step = max(1, -(-len(contour) // max_points))
    pts = contour[::step]
    return f"每 {GRID_SEC * step:.1f}s 一个点：" + " ".join("-" if p is None else str(int(p)) for p in pts)


def _describe(m: dict) -> str:
    d = CLIPS_DIR / m["id"]
    s = json.loads((d / "summary.json").read_text())
    tr = json.loads((d / "transcript.json").read_text())
    p = s["pitch"]
    rate = (len(tr["text"].replace(" ", "")) / s["voiced_sec"]) if s["voiced_sec"] else 0
    lines = [
        f"🎙️ {SPEAKER} 的语音 · {m['received']}（id {m['id']}）",
        f"时长 {s['duration_sec']}s，有声 {s['voiced_sec']}s（{round(s['speech_ratio'] * 100)}%），"
        f"语速约 {rate:.1f} 字/秒（有声部分）",
        "",
        "【说了什么】（本地 Whisper 转写，同音字可能有误）",
    ]
    lines += [f"[{x['start']:.1f}–{x['end']:.1f}s] {x['text']}" for x in tr["segments"]] or ["（没听出文字，可能是笑声、哼唱或环境音）"]
    lines += [
        "",
        "【怎么说的】",
        f"音高 {p['min']}–{p['max']} Hz，中位 {p['median']} Hz"
        + (f"；句尾是中位数的 {p['ending_vs_median']} 倍（>1.1 上扬，<0.9 下沉）" if p.get("ending_vs_median") else ""),
        f"停顿 {s['pause_count']} 次：" + ("、".join(f"{a}–{b}s" for a, b in s["pause_positions"]) or "无"),
        f"能量 平均 {s['energy_mean']} / 峰值 {s['energy_peak']}",
        f"基频曲线（Hz，- 为无声或清音）{_contour_text(s['pitch_contour'])}",
        "",
        "附图：上半是梅尔频谱，下半红线是语调、蓝色是响度、黄带是停顿。"
        "结合文字和语调去感受语气和情绪，回应的是人，不是数据。",
    ]
    return "\n".join(lines)


@mcp.tool(description=(
    f"听 {SPEAKER} 发来的语音。不传 clip_id 就听最新的一条。返回本地转写的文字（带时间戳）、"
    "语调/停顿/响度等韵律数字，以及一张梅尔频谱 + 基频/能量图。"
    f"当 {SPEAKER} 说「听听我的语音」「我给你发了语音」时调用。"))
def listen(clip_id: str = ""):
    clips = all_clips()
    if not clips:
        return f"还没有收到语音。让 {SPEAKER} 打开 {PUBLIC_URL or '录音页'} 录一段吧。"
    if clip_id:
        m = read_meta(clip_id.strip())
        if not m:
            return f"找不到 id 为 {clip_id} 的语音。可以先用 list_voice_messages 看看有哪些。"
    else:
        m = clips[0]
    st = m.get("status")
    if st in ("queued", "processing"):
        return f"最新一条语音（{m['received']}）还在处理中，通常几十秒，稍后再听一次。"
    if st == "error":
        return f"这条语音（{m['received']}）处理失败：{m.get('error')}"
    write_meta(m["id"], heard=time.time())
    png = CLIPS_DIR / m["id"] / "listen.png"
    return [_describe(m), Image(data=png.read_bytes(), format="png")]


@mcp.tool(description=(
    f"列出 {SPEAKER} 最近发来的语音（时间、时长、处理状态、是否听过、开头几个字）。"
    "想知道有没有没听的语音、或者要听某一条较早的语音时用。"))
def list_voice_messages(limit: int = 10):
    clips = all_clips()[:max(1, min(int(limit), 50))]
    if not clips:
        return "还没有收到语音。"
    out = []
    for m in clips:
        heard = "已听" if m.get("heard") else "🆕 未听"
        st = {"done": "", "queued": "排队中", "processing": "处理中", "error": "失败"}.get(m.get("status"), "")
        dur = f"{m['duration']}s" if m.get("duration") else ""
        out.append(f"- {m['received']} · {dur} · {st or heard} · id {m['id']}"
                   + (f" · 「{m.get('preview', '')}」" if m.get("preview") else ""))
    return "\n".join(out)


# ═══════════════════════════════════════════════════════════════════════
# 七、录音页（手机浏览器）
# ═══════════════════════════════════════════════════════════════════════
def _cookie_key() -> bytes:
    return hashlib.sha256(b"ears-cookie:" + OAUTH_PASSWORD.encode()).digest()


def _make_cookie() -> str:
    exp = str(int(time.time()) + COOKIE_TTL)
    return exp + "." + hmac.new(_cookie_key(), exp.encode(), hashlib.sha256).hexdigest()


def _cookie_ok(request: Request) -> bool:
    if not OAUTH_PASSWORD:
        return False
    v = request.cookies.get(COOKIE_NAME, "")
    exp, _, sig = v.partition(".")
    if not exp.isdigit() or int(exp) < time.time():
        return False
    good = hmac.new(_cookie_key(), exp.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(sig, good)


PAGE_CSS = """*{box-sizing:border-box}body{font-family:-apple-system,"PingFang SC",sans-serif;
background:#f3eefb;color:#3f3360;margin:0;padding:16px;min-height:100vh;display:flex;justify-content:center}
main{width:min(100%,420px)}.card{background:#fff;border-radius:20px;padding:22px;
box-shadow:0 10px 30px rgba(90,70,150,.12);margin-bottom:14px}h1{font-size:20px;margin:0 0 4px}
p.sub{font-size:13px;color:#8b7fb0;margin:0 0 18px}input[type=password]{width:100%;padding:11px 12px;
border:1px solid #d4c8f0;border-radius:12px;font-size:16px}button.go{margin-top:12px;width:100%;padding:12px;
border:0;border-radius:12px;background:#7c62d6;color:#fff;font-size:16px}.err{color:#c0392b;font-size:13px;margin-top:10px}
#rec{display:block;margin:6px auto 10px;width:132px;height:132px;border-radius:50%;border:0;background:#7c62d6;
color:#fff;font-size:17px;box-shadow:0 8px 24px rgba(124,98,214,.4);-webkit-tap-highlight-color:transparent}
#rec.on{background:#e0566b;box-shadow:0 0 0 10px rgba(224,86,107,.18),0 8px 24px rgba(224,86,107,.4);
animation:p 1.4s infinite}@keyframes p{50%{box-shadow:0 0 0 18px rgba(224,86,107,.08),0 8px 24px rgba(224,86,107,.4)}}
#timer{text-align:center;font-variant-numeric:tabular-nums;color:#8b7fb0;height:20px}
#status{text-align:center;font-size:14px;min-height:20px;margin-top:8px}label.up{display:block;text-align:center;
font-size:14px;color:#7c62d6;margin-top:14px;text-decoration:underline}label.up input{display:none}
#result img{width:100%;border-radius:10px;margin-top:10px}#result .t{white-space:pre-wrap;font-size:15px;line-height:1.6}
ul{list-style:none;padding:0;margin:0}li{font-size:13px;padding:8px 0;border-top:1px solid #eee8f8;color:#6b5f93}
li:first-child{border-top:0}h2{font-size:15px;margin:0 0 8px}"""

LOGIN_PAGE = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title><style>{css}</style></head>
<body><main><form class="card" method="post" action="{action}"><h1>{h1}</h1><p class="sub">{sub}</p>
{hidden}<input type="password" name="password" autofocus required autocomplete="current-password">
<button class="go" type="submit">{btn}</button>{err}</form></main></body></html>"""

RECORDER_PAGE = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>给 Lumi 发语音</title>
<style>{css}</style></head><body><main>
<div class="card"><h1>给 Lumi 发语音 👂</h1><p class="sub">按一下开始录，再按一下发送。发完回 Claude 说「听听我的语音」。</p>
<button id="rec">按一下录音</button><div id="timer"></div><div id="status"></div>
<label class="up">或者上传一段录音<input id="file" type="file" accept="audio/*,.m4a,.mp3,.wav,.webm,.ogg,.aac,.amr,.caf"></label></div>
<div class="card" id="result" hidden><h2>Lumi 听到的</h2><div class="t" id="text"></div><img id="img" alt="频谱图"></div>
<div class="card"><h2>最近的语音</h2><ul id="list"><li>…</li></ul></div>
</main><script>
const $=id=>document.getElementById(id);let mr=null,chunks=[],t0=0,tick=null;
function say(s){$('status').textContent=s}
function pickType(){for(const t of['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg'])
 if(window.MediaRecorder&&MediaRecorder.isTypeSupported&&MediaRecorder.isTypeSupported(t))return t;return''}
async function start(){
 if(!navigator.mediaDevices||!window.MediaRecorder){say('这个浏览器不支持网页录音，用下面的「上传」吧');return}
 let stream;try{stream=await navigator.mediaDevices.getUserMedia({audio:true})}
 catch(e){say('没拿到麦克风权限：'+e.message);return}
 const type=pickType();mr=new MediaRecorder(stream,type?{mimeType:type}:{});chunks=[];
 mr.ondataavailable=e=>{if(e.data&&e.data.size)chunks.push(e.data)};
 mr.onstop=()=>{stream.getTracks().forEach(t=>t.stop());const mt=mr.mimeType||type||'audio/mp4';
  const ext=mt.includes('webm')?'webm':mt.includes('ogg')?'ogg':'m4a';
  send(new Blob(chunks,{type:mt}),'voice.'+ext)};
 mr.start();t0=Date.now();$('rec').classList.add('on');$('rec').textContent='按一下发送';say('');
 tick=setInterval(()=>{const s=Math.floor((Date.now()-t0)/1000);
  $('timer').textContent=Math.floor(s/60)+':'+String(s%60).padStart(2,'0');if(s>={max})stop()},250)}
function stop(){if(mr&&mr.state!=='inactive')mr.stop();clearInterval(tick);
 $('rec').classList.remove('on');$('rec').textContent='按一下录音'}
$('rec').onclick=()=>{mr&&mr.state==='recording'?stop():start()};
$('file').onchange=e=>{const f=e.target.files[0];if(f)send(f,f.name);e.target.value=''};
async function send(blob,name){
 if(blob.size>{maxbytes}){say('文件太大了（上限 {maxmb}MB）');return}
 say('发送中…');const fd=new FormData();fd.append('audio',blob,name);
 try{const r=await fetch('upload',{method:'POST',body:fd});const j=await r.json();
  if(!r.ok)throw new Error(j.error||r.status);say('已送达，Lumi 正在听…');$('timer').textContent='';
  poll(j.id);load()}catch(e){say('发送失败：'+e.message)}}
async function poll(id){for(let i=0;i<180;i++){await new Promise(r=>setTimeout(r,2000));
 const r=await fetch('clips/'+id);if(!r.ok)continue;const j=await r.json();
 if(j.status==='done'){say('✅ 听完了，回 Claude 说「听听我的语音」吧');$('result').hidden=false;
  $('text').textContent=j.text||'（没听出文字）';$('img').src='clips/'+id+'/listen.png';load();return}
 if(j.status==='error'){say('处理失败：'+j.error);load();return}}}
async function load(){try{const r=await fetch('clips');const j=await r.json();
 $('list').innerHTML='';if(!j.length){$('list').innerHTML='<li>还没有</li>';return}
 for(const c of j){const li=document.createElement('li');
  li.textContent=c.received+' · '+(c.duration?c.duration+'s · ':'')+
   ({done:c.heard?'Lumi 听过了':'等 Lumi 来听',queued:'排队中',processing:'处理中',error:'失败'}[c.status]||c.status)+
   (c.preview?' · 「'+c.preview+'」':'');$('list').appendChild(li)}}catch(e){}}
load();
</script></body></html>"""


def _login_html(title, h1, sub, action, btn, hidden="", err="", status=200) -> HTMLResponse:
    body = (LOGIN_PAGE.replace("{css}", PAGE_CSS).replace("{title}", title).replace("{h1}", h1)
            .replace("{sub}", sub).replace("{action}", action).replace("{btn}", btn)
            .replace("{hidden}", hidden)
            .replace("{err}", f'<div class="err">{html.escape(err)}</div>' if err else ""))
    return HTMLResponse(body, status_code=status)


def _enter_page(err: str = "", status: int = 200) -> HTMLResponse:
    return _login_html("给 Lumi 发语音", "给 Lumi 发语音 👂", "输入耳朵服务的密码（30 天内这台手机不用再输）",
                       "enter", "进入", err=err, status=status)


async def index(request: Request):
    if not _cookie_ok(request):
        return _enter_page()
    body = (RECORDER_PAGE.replace("{css}", PAGE_CSS).replace("{max}", str(MAX_SECONDS))
            .replace("{maxbytes}", str(MAX_UPLOAD_MB * 1024 * 1024)).replace("{maxmb}", str(MAX_UPLOAD_MB)))
    return HTMLResponse(body, headers={"Cache-Control": "no-store"})


async def enter(request: Request):
    form = await request.form()
    pw = str(form.get("password", ""))
    if not OAUTH_PASSWORD or not hmac.compare_digest(pw.encode(), OAUTH_PASSWORD.encode()):
        await anyio.sleep(1.5)
        return _enter_page("密码不对，再试一次。", 401)
    resp = RedirectResponse("./", status_code=303)
    resp.set_cookie(COOKIE_NAME, _make_cookie(), max_age=COOKIE_TTL, httponly=True,
                    secure=PUBLIC_URL.startswith("https://"), samesite="lax")
    return resp


async def upload(request: Request):
    if not _cookie_ok(request):
        return JSONResponse({"error": "请先登录"}, status_code=401)
    form = await request.form(max_files=1, max_fields=5, max_part_size=MAX_UPLOAD_MB * 1024 * 1024)
    f = form.get("audio")
    if f is None or not hasattr(f, "read"):
        return JSONResponse({"error": "没收到音频"}, status_code=400)
    name = os.path.basename(f.filename or "voice.m4a")
    ext = os.path.splitext(name)[1].lower()
    if ext not in AUDIO_EXTS:
        ext = ".m4a" if "mp4" in (f.content_type or "") else ".bin"
    CLIPS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CLIPS_DIR / f".upload-{secrets.token_hex(6)}"
    size, limit = 0, MAX_UPLOAD_MB * 1024 * 1024
    try:
        with open(tmp, "wb") as out:
            while chunk := await f.read(1 << 20):
                size += len(chunk)
                if size > limit:
                    raise ValueError(f"文件太大（上限 {MAX_UPLOAD_MB}MB）")
                out.write(chunk)
        if size == 0:
            raise ValueError("文件是空的")
        cid = new_clip(tmp, ext, name[:80])
    except ValueError as e:
        tmp.unlink(missing_ok=True)
        return JSONResponse({"error": str(e)}, status_code=400)
    return JSONResponse({"id": cid, "status": "queued"})


async def clips_list(request: Request):
    if not _cookie_ok(request):
        return JSONResponse({"error": "请先登录"}, status_code=401)
    keys = ("id", "received", "duration", "status", "preview", "heard")
    return JSONResponse([{k: m.get(k) for k in keys} for m in all_clips()[:8]])


async def clip_status(request: Request):
    if not _cookie_ok(request):
        return JSONResponse({"error": "请先登录"}, status_code=401)
    cid = request.path_params["cid"]
    m = read_meta(cid)
    if not m:
        return JSONResponse({"error": "not found"}, status_code=404)
    out = {"id": cid, "status": m.get("status"), "error": m.get("error")}
    if m.get("status") == "done":
        tr = json.loads((CLIPS_DIR / cid / "transcript.json").read_text())
        out["text"] = tr["text"]
    return JSONResponse(out)


async def clip_png(request: Request):
    if not _cookie_ok(request):
        return JSONResponse({"error": "请先登录"}, status_code=401)
    d = _clip_dir(request.path_params["cid"])
    if not d or not (d / "listen.png").exists():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(d / "listen.png", media_type="image/png")


async def login(request: Request):
    """OAuth 授权页：claude.ai 添加连接器时跳到这里输密码。"""
    if not oauth:
        return JSONResponse({"error": "oauth disabled"}, status_code=404)
    expired = "授权请求已过期，请回到 Claude 重新连接。"

    def page(req, err="", status=200):
        hidden = f'<input type="hidden" name="req" value="{html.escape(req)}">'
        return _login_html("授权 Lumi 的耳朵", "授权 Claude 使用耳朵", "输入耳朵服务的密码（OAUTH_PASSWORD）",
                           "login", "授权", hidden=hidden, err=err, status=status)
    if request.method == "GET":
        req = request.query_params.get("req", "")
        return page(req) if oauth.pending_ok(req) else page("", expired, 400)
    form = await request.form()
    req, pw = str(form.get("req", "")), str(form.get("password", ""))
    if not oauth.pending_ok(req):
        return page("", expired, 400)
    if not hmac.compare_digest(pw.encode(), OAUTH_PASSWORD.encode()):
        await anyio.sleep(1.5)
        return page(req, "密码不对，再试一次。", 401)
    target = oauth.approve(req)
    return RedirectResponse(target, status_code=302) if target else page("", expired, 400)


async def healthz(request: Request):
    return JSONResponse({"ok": True, "oauth": OAUTH_ENABLED, "model": WHISPER_MODEL,
                         "model_loaded": _model is not None, "queue": _jobs.qsize()})


def main():
    CLIPS_DIR.mkdir(parents=True, exist_ok=True)
    if not OAUTH_ENABLED:
        print("❌ 需要 PUBLIC_URL 和 OAUTH_PASSWORD（录音页和连接器授权都靠它）", flush=True)
        return 1
    threading.Thread(target=worker, daemon=True, name="ears-worker").start()
    app = mcp.streamable_http_app()
    # 插到路由表最前面：streamable app 自带 lifespan，重新 Mount 会丢掉它
    for r in reversed([
        Route("/", endpoint=index),
        Route("/enter", endpoint=enter, methods=["POST"]),
        Route("/upload", endpoint=upload, methods=["POST"]),
        Route("/clips", endpoint=clips_list),
        Route("/clips/{cid}", endpoint=clip_status),
        Route("/clips/{cid}/listen.png", endpoint=clip_png),
        Route("/login", endpoint=login, methods=["GET", "POST"]),
        Route("/healthz", endpoint=healthz),
    ]):
        app.router.routes.insert(0, r)
    print(f"👂 ears-mcp → http://{HOST}:{PORT}/mcp   录音页 {PUBLIC_URL}/", flush=True)
    print(f"   whisper = {WHISPER_MODEL}（{WHISPER_LANGUAGE or '自动识别语言'}）  数据 = {DATA_DIR}", flush=True)
    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    sys.exit(main())

# ═══════════════════════════════════════════════════════════════════════
# CREDITS
#   · 耳蜗（梅尔频谱 + 基频/能量/停顿图 + 数字摘要）与本地 Whisper 速记的做法：
#     hmh323/mubai-ears（MIT）https://github.com/hmh323/mubai-ears
#     本文件把它改成了一台带录音页和 OAuth 的 MCP 服务器。
#   · OAuth 授权页与 FastMCP 补丁沿用本仓库 deploy/voice-card。
#   · MCP 协议与 Python SDK：modelcontextprotocol（MIT）
# ═══════════════════════════════════════════════════════════════════════
EARS_PY_EOF

# 2. Dockerfile + compose
$SUDO tee "$EARS_DIR/Dockerfile" >/dev/null <<DOCKERFILE
FROM python:3.12-slim
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s#http://deb.debian.org#$APT_MIRROR#g" /etc/apt/sources.list.d/debian.sources 2>/dev/null \\
      || sed -i "s#http://deb.debian.org#$APT_MIRROR#g" /etc/apt/sources.list; fi \\
 && apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-noto-cjk \\
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -i $PIP_INDEX "mcp>=1.9.0,<2" uvicorn python-multipart \\
    "librosa>=0.10" matplotlib numpy "faster-whisper>=1.0"
WORKDIR /app
COPY ears_mcp.py /app/ears_mcp.py
ENV HF_HUB_DISABLE_XET=1 EARS_DATA_DIR=/app/data WHISPER_MODEL_DIR=/app/models MPLCONFIGDIR=/tmp/mpl NUMBA_CACHE_DIR=/app/models/numba \\
    MCP_HOST=0.0.0.0 MCP_PORT=8000 PYTHONUNBUFFERED=1
CMD ["python", "-I", "/app/ears_mcp.py"]
DOCKERFILE

$SUDO tee "$EARS_DIR/docker-compose.yml" >/dev/null <<'YML'
services:
  ears:
    build: .
    image: ears:local
    container_name: ears
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${EARS_PORT:-18003}:8000"
    volumes:
      - ./data:/app/data
      - ./models:/app/models
YML

# 3. .env（只在第一次生成）
ENV_FILE="$EARS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机密码和静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# Lumi 的耳朵 —— 含密码，不要提交到 git、不要截图外传
EARS_PORT=$EARS_PORT
PUBLIC_URL=https://$EARS_DOMAIN
# 录音页登录 + claude.ai 添加连接器时授权，都用这个密码
OAUTH_PASSWORD=$(rand 20)
# 给能填请求头的客户端用：Authorization: Bearer <MCP_AUTH_TOKEN>
MCP_AUTH_TOKEN=$(rand 40)
# 转写：base 快、small 中文准（默认）、medium 更准但要 2GB+ 内存
WHISPER_MODEL=$WHISPER_MODEL
WHISPER_LANGUAGE=zh
# 国内服务器下载模型走 hf-mirror
${HF_ENDPOINT:+HF_ENDPOINT=$HF_ENDPOINT}
# 语音保留天数、单个文件上限、最长分析秒数
CLIP_KEEP_DAYS=30
MAX_UPLOAD_MB=25
MAX_SECONDS=600
EARS_SPEAKER=Timiya
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 构建并启动
log "构建镜像并启动（第一次要下载 Python 镜像、ffmpeg、中文字体和 Whisper 依赖，约 5–10 分钟）"
cd "$EARS_DIR"
$SUDO docker compose up -d --build

log "等待服务就绪（http://127.0.0.1:$EARS_PORT/healthz）"
ok=""
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$EARS_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { $SUDO docker compose logs --tail 40; die "服务没起来，上面是日志"; }
log "耳朵服务已启动 ✅"

warm || log "（模型下载失败也没关系：第一条语音来的时候会再试；可以稍后跑 sudo bash $0 --warm）"

# 5. 把域名加进 Ombre Brain 那条 Cloudflare 隧道（只增不删，不动已有的域名）
if [ -d "$CF_DIR" ] && [ -f "$CF_DIR/cert.pem" ]; then
  TID="$($SUDO ls "$CF_DIR" | grep -E '^[0-9a-f-]{36}\.json$' | head -1 | sed 's/\.json$//')"
  if [ -n "$TID" ]; then
    log "把 $EARS_DOMAIN 加进隧道 $TID"
    CF="$SUDO docker run --rm -v $CF_DIR:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"
    $CF tunnel route dns "$TID" "$EARS_DOMAIN" || log "（DNS 记录可能已存在，继续）"
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
    if ! $SUDO grep -q "hostname: $EARS_DOMAIN\$" "$CFG"; then
      $SUDO awk -v h="$EARS_DOMAIN" -v p="$EARS_PORT" \
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
  log "没找到 $CF_DIR/cert.pem，跳过隧道配置（需要自己把 $EARS_DOMAIN 指到 127.0.0.1:$EARS_PORT）"
fi

echo
echo "录音页：https://$EARS_DOMAIN （手机浏览器打开，输一次密码）"
echo "连接器地址：https://$EARS_DOMAIN/mcp"
echo "密码（录音页和连接器授权共用，看完别截图）：sudo grep OAUTH_PASSWORD $ENV_FILE"
