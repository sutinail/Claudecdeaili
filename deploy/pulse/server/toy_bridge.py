"""Toy Bridge 客户端 · toy_bridge.py
往 Supabase 命令信箱（device_commands）投递指令，iPhone 上 Bluefy 打开的页面领取后经蓝牙执行。
建表和 RPC 见仓库 claude/toy-bridge 分支的 toy/supabase.sql；强度上限、停止键都在手机页面上，这里不绕过任何一层。
"""

import json
import os
import urllib.error
import urllib.request

URL = os.getenv("TOY_SUPABASE_URL", "").rstrip("/")
KEY = os.getenv("TOY_ANON_KEY", "")
TOKEN = os.getenv("TOY_TOKEN", "")

CHANNELS = ("vibration", "suction", "thrust")
PATTERNS = ("steady", "pulse", "wave", "escalate")


def enabled() -> bool:
    return bool(URL and KEY and TOKEN)


def _rpc(fn: str, body: dict):
    headers = {"apikey": KEY, "Content-Type": "application/json"}
    # 旧版 anon key 是 JWT，要同时放进 Authorization；新版 sb_publishable_ key 只放 apikey
    if KEY.startswith("eyJ"):
        headers["Authorization"] = f"Bearer {KEY}"
    req = urllib.request.Request(f"{URL}/rest/v1/rpc/{fn}",
                                 data=json.dumps({"p_token": TOKEN, **body}).encode(),
                                 headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")
        try:
            detail = json.loads(detail).get("message", detail)
        except (ValueError, AttributeError):
            pass
        raise RuntimeError(detail) from None


def enqueue(action: str, **params) -> str:
    rows = _rpc("toy_enqueue", {"p_action": action, **{f"p_{k}": v for k, v in params.items()}})
    return rows[0]["id"]


def get(command_id: str) -> dict:
    return _rpc("toy_get", {"p_id": command_id})[0]
