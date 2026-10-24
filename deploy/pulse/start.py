"""
双服务启动器：API (:8300) + MCP (:8301)
共享同一个 PulseEngine，状态同步。
"""

import asyncio
import uvicorn
from server.vitals import PulseEngine
from server.mcp_server import create_mcp


class HostRewrite:
    """把任意 Host 头重写为 localhost，绕过 MCP SSE 的 host 校验。"""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            scope = dict(scope)
            scope["headers"] = [
                (b"host", b"localhost") if k == b"host" else (k, v)
                for k, v in scope.get("headers", [])
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

    mcp_app = HostRewrite(mcp_app)

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

    print("🫀 脉 · Pulse — API :8300 | MCP :8301")
    await asyncio.gather(api.serve(), mcp_srv.serve(), heartbeat())


if __name__ == "__main__":
    asyncio.run(main())
