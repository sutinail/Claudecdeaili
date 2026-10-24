"""
双服务启动器：API (:8300) + MCP (:8301)
共享同一个 PulseEngine，状态同步。
"""

import asyncio
import hmac
import os
from urllib.parse import parse_qs

import uvicorn
from server.vitals import PulseEngine
from server.mcp_server import create_mcp
from server.weather_fetch import fetch as fetch_weather

MCP_KEY = os.getenv("PULSE_MCP_KEY", "")


class McpGate:
    """/sse 必须带 ?key=PULSE_MCP_KEY；/messages 只认 /sse 发出的随机 session_id，不另验。
    MCP 的 DNS rebinding 白名单是 localhost:*，Host 必须带端口；Origin 也会被校验，直接去掉。"""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and MCP_KEY and scope["path"].rstrip("/") == "/sse":
            query = parse_qs(scope.get("query_string", b"").decode())
            key = query.get("key", [""])[0]
            if not hmac.compare_digest(key.encode(), MCP_KEY.encode()):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"unauthorized"})
                return
        if scope["type"] in ("http", "websocket"):
            scope = dict(scope)
            scope["headers"] = [
                (b"host", b"localhost:8301") if k == b"host" else (k, v)
                for k, v in scope.get("headers", []) if k != b"origin"
            ]
        await self.app(scope, receive, send)


async def main():
    engine = PulseEngine()

    # ── API ──
    from server.app import app
    app.state.pulse = engine

    api = uvicorn.Server(uvicorn.Config(
        app, host="0.0.0.0", port=8300, log_level="info",
    ))

    # ── MCP (standalone, no Mount) ──
    mcp = create_mcp(engine)
    try:
        mcp_app = create_mcp.get_sse_app(mcp)
    except Exception:
        mcp_app = mcp.sse_app()

    mcp_app = McpGate(mcp_app)
    if not MCP_KEY:
        print("⚠️ PULSE_MCP_KEY 没设，MCP 现在谁都能连")

    mcp_srv = uvicorn.Server(uvicorn.Config(
        mcp_app, host="0.0.0.0", port=8301, log_level="info",
    ))

    # ── Heartbeat ──
    async def heartbeat():
        while True:
            try:
                engine.tick()
            except Exception:
                pass
            await asyncio.sleep(8)

    # ── Weather (every 30 min) ──
    async def weather():
        while True:
            try:
                result = await asyncio.to_thread(fetch_weather)
                if result is None:
                    print("☁️ 没配置 PULSE_WEATHER_LAT/LON，天气停在默认 25°C")
                    return
                engine.weather.update(*result)
                print(f"☁️ 天气 {result[0]}°C {result[2]}")
            except Exception as err:
                print(f"☁️ 天气拉取失败：{err}")
            await asyncio.sleep(30 * 60)

    print("🫀 脉 · Pulse — API :8300 | MCP :8301", flush=True)
    await asyncio.gather(api.serve(), mcp_srv.serve(), heartbeat(), weather())


if __name__ == "__main__":
    asyncio.run(main())
