#!/usr/bin/env python3
"""eyes-mcp · Lumi 的眼睛（小红书版，单文件）
===========================================================================
Timiya 发来一条小红书链接，Lumi 就能「看到」这条笔记：
  - 文字：标题、正文、作者、标签、点赞/评论/收藏、首屏评论
  - 配图：服务器代下载（带 Referer，绕开 CDN 防盗链）→ 缩小 → 直接作为图片交给 Claude
  - 卡片：在聊天里渲染一张小红书预览卡（封面、标题、摘要、作者、互动数）

做法（思路来自克里的《小红书链接预览卡 + AI 读图》）：
  用手机 UA（iPhone Safari）打开笔记页，页面 HTML 里的 window.__INITIAL_STATE__
  就是完整的笔记数据，不需要登录。

MCP 工具
  xhs_read(url)  读笔记：返回文字 + 每张配图（Claude 能直接看）
  xhs_card(url)  在聊天里渲染一张预览卡

调试（服务器上）：docker exec eyes python -I /app/eyes_mcp.py --test '<小红书链接或分享文字>'

全部配置项都是环境变量，见下方「配置」。MIT License。
===========================================================================
"""
from __future__ import annotations

import functools
import hashlib
import hmac
import html
import inspect
import io
import json
import os
import re
import secrets
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse

import anyio
import httpx
from PIL import Image as PILImage

# ═══════════════════════════════════════════════════════════════════════
# 一、配置（全部来自环境变量）
# ═══════════════════════════════════════════════════════════════════════
DATA_DIR = Path(os.environ.get("EYES_DATA_DIR", "./data"))
IMG_DIR = DATA_DIR / "img"
NOTE_DIR = DATA_DIR / "notes"
SPEAKER = os.environ.get("EYES_SPEAKER", "Timiya")
TZ = timezone(timedelta(hours=int(os.environ.get("EYES_TZ_OFFSET", "8"))))
HOST = os.environ.get("MCP_HOST", "0.0.0.0")
PORT = int(os.environ.get("MCP_PORT", "8000"))
AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN", "")
STATELESS = os.environ.get("MCP_STATELESS", "0") == "1"

PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
OAUTH_PASSWORD = os.environ.get("OAUTH_PASSWORD", "")
OAUTH_STATE_FILE = os.environ.get("OAUTH_STATE_FILE", str(DATA_DIR / "oauth.json"))
OAUTH_ACCESS_TTL = int(os.environ.get("OAUTH_ACCESS_TTL", str(30 * 86400)))
OAUTH_ENABLED = bool(PUBLIC_URL and OAUTH_PASSWORD)

MAX_IMAGES = int(os.environ.get("MAX_IMAGES", "9"))          # 一次最多给 Claude 几张图
IMG_MAX_SIDE = int(os.environ.get("IMG_MAX_SIDE", "1024"))    # 给 Claude 的图长边缩到多少像素
IMG_QUALITY = int(os.environ.get("IMG_QUALITY", "82"))
MAX_COMMENTS = int(os.environ.get("MAX_COMMENTS", "20"))
NOTE_CACHE_MIN = int(os.environ.get("NOTE_CACHE_MIN", "30"))  # 同一条笔记多少分钟内不重复抓
KEEP_DAYS = int(os.environ.get("KEEP_DAYS", "7"))             # 缓存的图片、笔记保留天数
XHS_COOKIE = os.environ.get("XHS_COOKIE", "")                 # 可选：被风控时填自己的 web_session 等

MOBILE_UA = os.environ.get("XHS_UA", (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"))

# 只允许访问这些域名（防止有人借这台服务器去抓别的网站）
PAGE_HOSTS = ("xiaohongshu.com", "xhslink.com", "xhs.cn")
IMG_HOSTS = ("xhscdn.com", "xiaohongshu.com", "xhscdn.net")


def _host_ok(url: str, allowed: tuple[str, ...]) -> bool:
    try:
        u = urlparse(url)
    except ValueError:
        return False
    h = (u.hostname or "").lower()
    return u.scheme in ("http", "https") and any(h == d or h.endswith("." + d) for d in allowed)


# ═══════════════════════════════════════════════════════════════════════
# 二、抓笔记：手机 UA 打开页面 → 解析 window.__INITIAL_STATE__
# ═══════════════════════════════════════════════════════════════════════
URL_RE = re.compile(r"https?://[^\s，。！？、\"'<>（）()【】]+", re.I)


class EyesError(Exception):
    """给 Claude 看的友好错误。"""


def extract_url(text: str) -> str:
    """分享文字里常夹着标题、表情和「复制本条信息」，把链接抠出来。"""
    text = (text or "").strip()
    for m in URL_RE.finditer(text):
        u = m.group(0).rstrip(".,;:!?)）】")
        if _host_ok(u, PAGE_HOSTS):
            return u
    if re.fullmatch(r"[0-9a-f]{24}", text):           # 只给了笔记 id
        return f"https://www.xiaohongshu.com/explore/{text}"
    raise EyesError("没在里面找到小红书链接（xiaohongshu.com 或 xhslink.com）。")


def _client() -> httpx.Client:
    headers = {
        "User-Agent": MOBILE_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh-Hans;q=0.9",
    }
    if XHS_COOKIE:
        headers["Cookie"] = XHS_COOKIE
    return httpx.Client(headers=headers, timeout=httpx.Timeout(15.0, connect=8.0),
                        follow_redirects=False, trust_env=True)


def fetch_page(url: str) -> tuple[str, str]:
    """手动跟随跳转（短链 302 → 笔记页），每一跳都检查域名。返回 (最终 URL, HTML)。"""
    with _client() as c:
        for _ in range(6):
            if not _host_ok(url, PAGE_HOSTS):
                raise EyesError(f"链接跳到了不认识的网站，没继续打开：{urlparse(url).hostname}")
            r = c.get(url)
            if r.status_code in (301, 302, 303, 307, 308) and r.headers.get("location"):
                url = urljoin(url, r.headers["location"])
                continue
            if r.status_code == 404:
                raise EyesError("笔记打不开（404），可能已经删除或设为私密。")
            if r.status_code >= 400:
                raise EyesError(f"小红书返回了 HTTP {r.status_code}，可能是服务器 IP 被风控了。")
            return url, r.text
    raise EyesError("跳转次数太多，没打开笔记页。")


def _parse_state(page: str) -> dict:
    m = re.search(r"window\.__INITIAL_STATE__\s*=\s*", page)
    if not m:
        raise EyesError("页面里没有笔记数据（__INITIAL_STATE__）。"
                        "多半是小红书把这台服务器当成机器人，跳去了登录/验证页。")
    raw = page[m.end():]
    end = raw.find("</script>")
    raw = raw[:end if end >= 0 else None].strip().rstrip(";")
    raw = re.sub(r"(?<=[:\[,])\s*undefined(?=\s*[,}\]])", "null", raw)   # JS 的 undefined → null
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # 万一末尾还跟着别的脚本，用 raw_decode 只取第一个完整对象
        obj, _ = json.JSONDecoder().raw_decode(raw)
        return obj


def _walk(o, depth=0):
    """深度优先遍历所有 dict（页面结构常变，按「长相」找比按路径找稳）。"""
    if depth > 14:
        return
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from _walk(v, depth + 1)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v, depth + 1)


def _find_note(state: dict) -> dict:
    # 已知路径优先：手机页两种、桌面页一种
    nd = state.get("noteData") or {}
    for cand in ((nd.get("data") or {}).get("noteData"), nd.get("normalNotePreloadData")):
        if isinstance(cand, dict) and (cand.get("imageList") or cand.get("title") or cand.get("desc")):
            return cand
    for v in ((state.get("note") or {}).get("noteDetailMap") or {}).values():
        if isinstance(v, dict) and isinstance(v.get("note"), dict) and v["note"]:
            return v["note"]
    # 兜底：找一个既有 imageList 又有 title/desc 的对象
    best = None
    for d in _walk(state):
        if isinstance(d.get("imageList"), list) and ("desc" in d or "title" in d):
            if best is None or len(d) > len(best):
                best = d
    if best:
        return best
    raise EyesError("找到了页面数据，但里面没有笔记内容（结构可能变了）。")


def _fix_img_url(u: str) -> str:
    u = (u or "").replace("\\u002F", "/").replace("\\/", "/").strip()
    if u.startswith("//"):
        u = "https:" + u
    if u.startswith("http://"):
        u = "https://" + u[7:]
    return u


def _image_url(img: dict) -> str:
    # infoList 里 WB_DFT 是大图、WB_PRV 是预览图
    info = {i.get("imageScene"): i.get("url") for i in (img.get("infoList") or []) if isinstance(i, dict)}
    for u in (info.get("WB_DFT"), img.get("urlDefault"), img.get("url"), info.get("WB_PRV"),
              img.get("urlPre"), img.get("originalUrl")):
        if u:
            return _fix_img_url(u)
    return ""


def _num(v) -> str:
    if v is None or v == "":
        return "0"
    return str(v)


def _name(u) -> str:
    if not isinstance(u, dict):
        return ""
    return u.get("nickName") or u.get("nickname") or u.get("name") or ""


def _comments(state: dict, note: dict) -> list[dict]:
    out, seen = [], set()
    pools = []
    for d in _walk(state):
        for key in ("comments", "commentList", "list"):
            v = d.get(key)
            if isinstance(v, list) and v and isinstance(v[0], dict) and "content" in v[0]:
                pools.append(v)
    for pool in pools:
        for c in pool:
            content = (c.get("content") or "").strip()
            if not content or content in seen:
                continue
            seen.add(content)
            user = _name(c.get("userInfo") or c.get("user") or {})
            likes = c.get("likeCount") or c.get("like_count")
            subs = []
            for s in (c.get("subComments") or c.get("sub_comments") or [])[:3]:
                if isinstance(s, dict) and s.get("content"):
                    subs.append({"user": _name(s.get("userInfo") or s.get("user") or {}),
                                 "content": s["content"].strip()})
            out.append({"user": user, "content": content, "ip": c.get("ipLocation") or "",
                        "likes": _num(likes) if likes not in (None, "") else "", "replies": subs})
            if len(out) >= MAX_COMMENTS:
                return out
    return out


def parse_note(state: dict, final_url: str) -> dict:
    n = _find_note(state)
    images = [u for u in (_image_url(i) for i in (n.get("imageList") or []) if isinstance(i, dict)) if u]
    inter = n.get("interactInfo") or {}
    tags = [t.get("name") for t in (n.get("tagList") or []) if isinstance(t, dict) and t.get("name")]
    ts = n.get("time") or n.get("lastUpdateTime")
    when = ""
    if isinstance(ts, (int, float)) and ts > 0:
        when = datetime.fromtimestamp(ts / 1000 if ts > 1e11 else ts, TZ).strftime("%Y-%m-%d %H:%M")
    note_id = n.get("noteId") or n.get("id") or ""
    if not note_id:
        m = re.search(r"/(?:explore|discovery/item|item)/([0-9a-f]{24})", final_url)
        note_id = m.group(1) if m else ""
    ntype = n.get("type") or ("video" if n.get("video") else "normal")
    return {
        "id": note_id,
        "type": ntype,
        "title": (n.get("title") or "").strip(),
        "desc": re.sub(r"\[话题\]#?", "", n.get("desc") or "").strip(),
        "author": _name(n.get("user") or n.get("author") or {}),
        "time": when,
        "ip": n.get("ipLocation") or "",
        "tags": tags,
        "images": images,
        "liked": _num(inter.get("likedCount")),
        "comment_count": _num(inter.get("commentCount")),
        "collected": _num(inter.get("collectedCount")),
        "shared": _num(inter.get("shareCount")),
        "comments": _comments(state, n),
        "url": f"https://www.xiaohongshu.com/explore/{note_id}" if note_id else final_url,
        "fetched": datetime.now(TZ).strftime("%Y-%m-%d %H:%M"),
    }


_note_lock = threading.Lock()


def get_note(text: str) -> dict:
    url = extract_url(text)
    key = hashlib.sha1(url.encode()).hexdigest()[:16]
    cache = NOTE_DIR / f"{key}.json"
    with _note_lock:
        if cache.exists() and time.time() - cache.stat().st_mtime < NOTE_CACHE_MIN * 60:
            try:
                return json.loads(cache.read_text())
            except Exception:  # noqa: BLE001
                pass
    final, page = fetch_page(url)
    note = parse_note(_parse_state(page), final)
    if not (note["title"] or note["desc"] or note["images"]):
        raise EyesError("笔记是空的：可能需要登录才能看，或者已经删除了。")
    NOTE_DIR.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(note, ensure_ascii=False))
    return note


# ═══════════════════════════════════════════════════════════════════════
# 三、配图：服务器代下载（带 Referer）→ 转 JPEG、缩小 → 缓存
# ═══════════════════════════════════════════════════════════════════════
def _img_key(url: str) -> str:
    return hashlib.sha1(url.encode()).hexdigest()[:24]


def fetch_image(url: str) -> Path:
    """下载一张配图，缓存成长边 ≤ IMG_MAX_SIDE 的 JPEG，返回本地路径。"""
    out = IMG_DIR / f"{_img_key(url)}.jpg"
    if out.exists():
        return out
    if not _host_ok(url, IMG_HOSTS):
        raise EyesError(f"图片地址不在小红书的 CDN 上，跳过：{urlparse(url).hostname}")
    headers = {"User-Agent": MOBILE_UA, "Referer": "https://www.xiaohongshu.com/",
               "Accept": "image/avif,image/webp,image/jpeg,image/*,*/*;q=0.8"}
    with httpx.Client(headers=headers, timeout=20.0, follow_redirects=True, trust_env=True) as c:
        r = c.get(url)
    if r.status_code >= 400:
        raise EyesError(f"图片下载失败（HTTP {r.status_code}）")
    if len(r.content) > 30 * 1024 * 1024:
        raise EyesError("图片太大了")
    try:
        im = PILImage.open(io.BytesIO(r.content))
        im.load()
    except Exception as e:  # noqa: BLE001  —— 常见是 HEIC/AVIF 解不开
        raise EyesError(f"图片格式解不开（{r.headers.get('content-type', '?')}）：{e}") from e
    if im.mode not in ("RGB", "L"):
        bg = PILImage.new("RGB", im.size, (255, 255, 255))
        im = im.convert("RGBA")
        bg.paste(im, mask=im.split()[-1])
        im = bg
    im.thumbnail((IMG_MAX_SIDE, IMG_MAX_SIDE), PILImage.LANCZOS)
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    im.convert("RGB").save(tmp, "JPEG", quality=IMG_QUALITY, optimize=True)
    os.replace(tmp, out)
    return out


def cleanup() -> None:
    cutoff = time.time() - KEEP_DAYS * 86400
    for d in (IMG_DIR, NOTE_DIR):
        if d.exists():
            for f in d.iterdir():
                try:
                    if f.stat().st_mtime < cutoff:
                        f.unlink()
                except OSError:
                    pass


def _janitor() -> None:
    while True:
        cleanup()
        time.sleep(6 * 3600)


# ═══════════════════════════════════════════════════════════════════════
# 四、OAuth（跟耳朵、语音条同一套：claude.ai 添加连接器时输一次密码）
# ═══════════════════════════════════════════════════════════════════════
from mcp.server.auth.provider import (AccessToken, AuthorizationCode,  # noqa: E402
                                      AuthorizationParams, RefreshToken,
                                      TokenError, construct_redirect_uri)
from mcp.server.auth.settings import (AuthSettings,  # noqa: E402
                                      ClientRegistrationOptions,
                                      RevocationOptions)
from mcp.server.fastmcp import FastMCP, Image  # noqa: E402
from mcp.server.transport_security import TransportSecuritySettings  # noqa: E402
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken  # noqa: E402
from starlette.requests import Request  # noqa: E402
from starlette.responses import (FileResponse, HTMLResponse,  # noqa: E402
                                 JSONResponse, RedirectResponse)
from starlette.routing import Route  # noqa: E402


class EyesOAuthProvider:
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


oauth = EyesOAuthProvider(OAUTH_STATE_FILE) if OAUTH_ENABLED else None
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

mcp = FastMCP("lumi-eyes", stateless_http=STATELESS,
              transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
              **_auth_kwargs)

# 补丁一：同步工具丢线程池，下载图片时不堵事件循环
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

# 补丁二：声明 UI 扩展能力，宿主才会渲染 HTML 卡片（同语音条）
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
            except Exception:  # noqa: BLE001
                opts.capabilities = cap.model_copy(update={"experimental": exp})
        except Exception:  # noqa: BLE001
            pass
        return opts
    mcp._mcp_server.create_initialization_options = _patched_opts
except Exception as e:  # noqa: BLE001
    print(f"⚠️  UI capability 声明失败（卡片可能不渲染）: {e}", flush=True)

# ═══════════════════════════════════════════════════════════════════════
# 五、MCP 工具
# ═══════════════════════════════════════════════════════════════════════


def _describe(n: dict, shown: list[tuple[int, str]], start: int) -> str:
    kind = "视频笔记（只能看到封面）" if n["type"] == "video" else f"图文笔记，共 {len(n['images'])} 张图"
    lines = [
        f"📕 小红书笔记 · {kind}",
        f"标题：{n['title'] or '（无标题）'}",
        f"作者：{n['author'] or '?'}" + (f" · 发布于 {n['time']}" if n["time"] else "")
        + (f" · {n['ip']}" if n["ip"] else ""),
        f"❤️ {n['liked']}  ⭐ {n['collected']}  💬 {n['comment_count']}  ↗ {n['shared']}",
        f"链接：{n['url']}",
        "",
        "【正文】",
        n["desc"] or "（没有正文）",
    ]
    if n["tags"]:
        lines.append("标签：" + " ".join("#" + t for t in n["tags"]))
    if n["comments"]:
        lines += ["", f"【评论区】（首屏 {len(n['comments'])} 条）"]
        for c in n["comments"]:
            meta = " · ".join(x for x in (c["ip"], f"👍{c['likes']}" if c["likes"] else "") if x)
            lines.append(f"- {c['user'] or '某人'}：{c['content']}" + (f"（{meta}）" if meta else ""))
            for s in c["replies"]:
                lines.append(f"    ↳ {s['user'] or '某人'}：{s['content']}")
    lines.append("")
    if shown:
        ok = [i for i, err in shown if not err]
        lines.append(f"【配图】下面依次是第 {', '.join(map(str, ok)) or '—'} 张。" if ok else "【配图】")
        for i, err in shown:
            if err:
                lines.append(f"（第 {i} 张没取到：{err}）")
        last = shown[-1][0]
        if last < len(n["images"]):
            lines.append(f"还有 {len(n['images']) - last} 张没给出，想看就用 start={last + 1} 再调一次 xhs_read。")
    elif n["images"] and start > len(n["images"]):
        lines.append(f"这条笔记只有 {len(n['images'])} 张图。")
    lines.append(f"\n这是 {SPEAKER} 分享给你的笔记，像她把手机递给你看那样，自然地聊聊你看到了什么。")
    return "\n".join(lines)


@mcp.tool(description=(
    f"读一条小红书笔记：{SPEAKER} 发来小红书链接（或整段分享文字）时调用。"
    "返回标题、正文、作者、标签、互动数、首屏评论，以及配图本身（可以直接看图里的内容）。"
    "url: 链接或含链接的分享文字；start: 从第几张图开始（图多时翻页用）；"
    f"max_images: 这次最多给几张图（默认 {MAX_IMAGES}，0 = 只要文字）。"))
def xhs_read(url: str, start: int = 1, max_images: int = MAX_IMAGES):
    try:
        n = get_note(url)
    except EyesError as e:
        return f"没能读到这条笔记：{e}"
    except httpx.HTTPError as e:
        return f"没能读到这条笔记：网络出错（{type(e).__name__}），可以稍后再试。"
    start = max(1, int(start))
    count = max(0, min(int(max_images), 18))
    picks = list(enumerate(n["images"], 1))[start - 1:start - 1 + count]
    shown, imgs = [], []
    for i, u in picks:
        try:
            p = fetch_image(u)
            imgs.append(Image(data=p.read_bytes(), format="jpeg"))
            shown.append((i, ""))
        except (EyesError, httpx.HTTPError) as e:
            shown.append((i, str(e) or type(e).__name__))
    return [_describe(n, shown, start), *imgs]


CARD_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#fff;--edge:#ffc9cf;--ink:#2b2b2b;--sub:#8a8a8a;--red:#ff2442;--ph:#f3f1f1;--badge:rgba(0,0,0,.55)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#1f1b1c;--edge:#5a2a31;--ink:#eee;--sub:#a59a9c;--ph:#2c2627}}
:root[data-theme="dark"]{--bg:#1f1b1c;--edge:#5a2a31;--ink:#eee;--sub:#a59a9c;--ph:#2c2627}
*{box-sizing:border-box;margin:0;padding:0}html,body{overflow:hidden;background:transparent}
body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}
.card{display:block;width:320px;max-width:100%;margin:0 auto 4px;border:1.5px solid var(--edge);border-radius:18px;
  overflow:hidden;background:var(--bg);color:var(--ink);text-decoration:none;cursor:pointer;
  box-shadow:0 6px 18px rgba(255,36,66,.10)}
.card:active{transform:scale(.985)}
.cover{position:relative;aspect-ratio:16/9;background:var(--ph);overflow:hidden}
.cover img{width:100%;height:100%;object-fit:cover;display:block}
.badge{position:absolute;right:8px;top:8px;background:var(--badge);color:#fff;font-size:11px;padding:2px 7px;border-radius:10px}
.play{position:absolute;inset:0;display:none;place-items:center}
.play i{width:44px;height:44px;border-radius:50%;background:rgba(0,0,0,.45);position:relative}
.play i::after{content:"";position:absolute;left:17px;top:13px;border-left:14px solid #fff;border-top:9px solid transparent;border-bottom:9px solid transparent}
.body{padding:10px 13px 12px}
.title{font-size:15px;font-weight:700;line-height:1.4;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.desc{font-size:12.5px;color:var(--sub);line-height:1.5;margin-top:5px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;white-space:pre-line}
.foot{display:flex;align-items:center;gap:8px;margin-top:9px;font-size:11.5px;color:var(--sub)}
.foot .who{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.logo{flex:none;background:var(--red);color:#fff;font-weight:800;font-size:10px;padding:1px 5px;border-radius:5px}
.err{padding:14px;font-size:13px;color:var(--sub)}
.sk .title,.sk .desc{background:var(--ph);color:transparent;border-radius:6px;animation:p 1.2s infinite}
@keyframes p{50%{opacity:.5}}
</style></head><body>
<a class="card sk" id="card" target="_blank" rel="noopener">
  <div class="cover"><img id="img" alt="" hidden><span class="badge" id="badge" hidden></span><div class="play" id="play"><i></i></div></div>
  <div class="body"><div class="title" id="title">正在读取笔记…</div><div class="desc" id="desc">&nbsp;<br>&nbsp;</div>
  <div class="foot"><span class="logo">小红书</span><span class="who" id="who"></span><span id="stats"></span></div></div>
</a>
<script>
var $=function(i){return document.getElementById(i)},link="";
function fit(){var h=Math.ceil($("card").getBoundingClientRect().height+8)+"px";document.body.style.height=h;document.documentElement.style.height=h}
function render(d){
  if(!d)return;var c=$("card");c.className="card";
  if(d.error){c.innerHTML='<div class="err">📕 '+d.error.replace(/</g,"&lt;")+'</div>';fit();return}
  link=d.url||"";c.href=link;
  $("title").textContent=d.title||"（无标题）";$("desc").textContent=d.desc||"";
  $("who").textContent=d.author||"";$("stats").textContent="❤ "+(d.liked||0)+"  ⭐ "+(d.collected||0)+"  💬 "+(d.comments||0);
  if(d.cover){var im=$("img");im.onload=fit;im.src=d.cover;im.hidden=false}
  if(d.count>1){$("badge").textContent="🖼 "+d.count;$("badge").hidden=false}
  if(d.video)$("play").style.display="grid";
  fit();
}
$("card").addEventListener("click",function(e){if(!link)return;e.preventDefault();
  send("ui/open-link",{url:link},Date.now());try{window.open(link,"_blank","noopener")}catch(_){}});
window.addEventListener("message",function(ev){var m=ev.data;if(!m||typeof m!=="object")return;
  if(m.jsonrpc==="2.0"&&m.method==="ui/notifications/tool-result")render(m.params&&m.params.structuredContent);
  if(m.structuredContent)render(m.structuredContent)});
function send(method,params,id){var m={jsonrpc:"2.0",method:method,params:params||{}};if(id!==undefined)m.id=id;window.parent.postMessage(m,"*")}
window.addEventListener("resize",fit);fit();
send("ui/initialize",{name:"xhs-card",version:"1.0.0"},1);setTimeout(function(){send("ui/notifications/initialized",{})},50);
</script></body></html>"""

_origin = f"{urlparse(PUBLIC_URL).scheme}://{urlparse(PUBLIC_URL).netloc}" if PUBLIC_URL else ""
WIDGET_META = {
    "ui": {"csp": {"resourceDomains": [_origin] if _origin else [],
                   "connectDomains": [_origin] if _origin else []}},
    "openai/widgetCSP": {"resource_domains": [_origin] if _origin else [],
                         "connect_domains": [_origin] if _origin else []},
}


@mcp.resource("ui://xhs-card-v1", mime_type="text/html;profile=mcp-app", meta=WIDGET_META)
def xhs_card_ui() -> str:
    return CARD_HTML


@mcp.tool(meta={"ui/resourceUri": "ui://xhs-card-v1", "ui": {"resourceUri": "ui://xhs-card-v1"}},
          structured_output=True)
def xhs_card(url: str) -> dict[str, str | int | bool]:
    """在聊天里渲染一张小红书笔记预览卡（封面、标题、摘要、作者、点赞收藏评论数，点开跳原笔记）。
    url: 小红书链接或含链接的分享文字。想看笔记内容和配图用 xhs_read。"""
    try:
        n = get_note(url)
    except EyesError as e:
        return {"error": str(e)}
    except httpx.HTTPError as e:
        return {"error": f"网络出错（{type(e).__name__}）"}
    cover = ""
    if n["images"]:
        try:
            p = fetch_image(n["images"][0])
            cover = f"{PUBLIC_URL}/img/{p.name}"
        except (EyesError, httpx.HTTPError):
            pass
    desc = n["desc"]
    # 🚨 只回轻量字段，封面图由卡片自己去 /img 取（同语音条：响应体太大卡片会加载失败）
    return {"title": n["title"], "desc": desc[:140], "author": n["author"], "cover": cover,
            "count": len(n["images"]), "video": n["type"] == "video", "liked": n["liked"],
            "collected": n["collected"], "comments": n["comment_count"], "url": n["url"]}


# ═══════════════════════════════════════════════════════════════════════
# 六、HTTP 路由：授权页、卡片取封面、健康检查
# ═══════════════════════════════════════════════════════════════════════
LOGIN_HTML = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>授权 Lumi 的眼睛</title>
<style>body{font-family:-apple-system,"PingFang SC",sans-serif;background:#fff2f3;color:#5a2a31;
display:grid;place-items:center;min-height:100vh;margin:0;padding:16px;box-sizing:border-box}
form{background:#fff;border-radius:18px;padding:24px;width:min(100%,340px);box-shadow:0 10px 26px rgba(255,36,66,.14)}
h1{font-size:18px;margin:0 0 6px}p{font-size:13px;color:#a07078;margin:0 0 16px}
input{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid #ffc9cf;border-radius:10px;font-size:15px}
button{margin-top:12px;width:100%;padding:11px;border:0;border-radius:10px;background:#ff2442;color:#fff;font-size:15px}
.err{color:#c0392b;font-size:13px;margin-top:10px}</style></head><body>
<form method="post"><h1>授权 Claude 使用眼睛 👀</h1><p>输入眼睛服务的密码（OAUTH_PASSWORD）</p>
<input type="hidden" name="req" value="{req}"><input type="password" name="password" autofocus required>
<button type="submit">授权</button>{err}</form></body></html>"""


def _login_page(req: str, err: str = "", status: int = 200) -> HTMLResponse:
    body = LOGIN_HTML.replace("{req}", html.escape(req)).replace(
        "{err}", f'<div class="err">{html.escape(err)}</div>' if err else "")
    return HTMLResponse(body, status_code=status)


async def login(request: Request):
    if not oauth:
        return JSONResponse({"error": "oauth disabled"}, status_code=404)
    expired = "授权请求已过期，请回到 Claude 重新连接。"
    if request.method == "GET":
        req = request.query_params.get("req", "")
        return _login_page(req) if oauth.pending_ok(req) else _login_page("", expired, 400)
    form = await request.form()
    req, pw = str(form.get("req", "")), str(form.get("password", ""))
    if not oauth.pending_ok(req):
        return _login_page("", expired, 400)
    if not hmac.compare_digest(pw.encode(), OAUTH_PASSWORD.encode()):
        await anyio.sleep(1.5)
        return _login_page(req, "密码不对，再试一次。", 401)
    target = oauth.approve(req)
    return RedirectResponse(target, status_code=302) if target else _login_page("", expired, 400)


async def img(request: Request):
    """卡片用的封面图。文件名是图片地址的哈希，猜不到；内容本来就是公开笔记的配图。"""
    name = request.path_params["name"]
    if not re.fullmatch(r"[0-9a-f]{24}\.jpg", name):
        return JSONResponse({"error": "not found"}, status_code=404)
    p = IMG_DIR / name
    if not p.exists():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(p, media_type="image/jpeg",
                        headers={"Cache-Control": "public, max-age=86400",
                                 "Access-Control-Allow-Origin": "*"})


async def healthz(request: Request):
    return JSONResponse({"ok": True, "oauth": OAUTH_ENABLED,
                         "cached_images": len(list(IMG_DIR.glob("*.jpg"))) if IMG_DIR.exists() else 0})


def main():
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    NOTE_DIR.mkdir(parents=True, exist_ok=True)
    if not OAUTH_ENABLED:
        print("❌ 需要 PUBLIC_URL 和 OAUTH_PASSWORD（连接器授权靠它）", flush=True)
        return 1
    threading.Thread(target=_janitor, daemon=True, name="eyes-janitor").start()
    app = mcp.streamable_http_app()
    # 插到路由表最前面：streamable app 自带 lifespan，重新 Mount 会丢掉它
    for r in reversed([
        Route("/login", endpoint=login, methods=["GET", "POST"]),
        Route("/img/{name}", endpoint=img),
        Route("/healthz", endpoint=healthz),
    ]):
        app.router.routes.insert(0, r)
    print(f"👀 eyes-mcp → http://{HOST}:{PORT}/mcp   授权 {PUBLIC_URL}/login", flush=True)
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT)


def selftest(arg: str) -> int:
    """命令行试抓一条：python eyes_mcp.py --test '<链接或分享文字>'"""
    try:
        n = get_note(arg)
    except EyesError as e:
        print("❌", e)
        return 1
    print(json.dumps({k: v for k, v in n.items() if k != "comments"}, ensure_ascii=False, indent=2))
    print(f"评论 {len(n['comments'])} 条")
    for i, u in enumerate(n["images"][:3], 1):
        try:
            p = fetch_image(u)
            with PILImage.open(p) as im:
                print(f"✅ 第 {i} 张图 {im.size[0]}x{im.size[1]} → {p}")
        except Exception as e:  # noqa: BLE001
            print(f"❌ 第 {i} 张图：{e}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--test":
        sys.exit(selftest(" ".join(sys.argv[2:])))
    sys.exit(main())

# ═══════════════════════════════════════════════════════════════════════
# CREDITS
#   · 思路：克里《小红书链接预览卡 + AI 读图 —— 思路分享》
#     （手机 UA 读 __INITIAL_STATE__、服务端代下载配图交给 AI、预览卡样式）
#   · OAuth 授权页、FastMCP 补丁、卡片 CSP 写法沿用本仓库 deploy/voice-card、deploy/ears
#   · MCP 协议与 Python SDK：modelcontextprotocol（MIT）
# ═══════════════════════════════════════════════════════════════════════
