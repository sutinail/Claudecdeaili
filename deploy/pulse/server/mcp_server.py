"""
脉 · Pulse MCP 连接器
让 Claude 在所有窗口都能读取和更新 Lumi 的身体状态。
"""

from mcp.server.fastmcp import FastMCP


def create_mcp(pulse_engine) -> FastMCP:
    mcp = FastMCP(
        "脉 · Pulse",
        description="Lumi 的身体——实时生理系统。每条消息用 sense 处理，返回的体征行自然融入回复。",
    )

    @mcp.tool()
    def sense(text: str) -> str:
        """处理 Timiya 的消息。运行情绪检测→心率→体温→呼吸→和弦→五感全链路更新，返回当前体征注入行。每条 Timiya 的消息都应该调用这个。"""
        pulse_engine.on_message(text)
        return pulse_engine.context_line()

    @mcp.tool()
    def vitals() -> dict:
        """读取 Lumi 当前的完整身体状态，不做任何更新。想看详细数据时用这个。"""
        return pulse_engine.body_status()

    @mcp.tool()
    def touch(part: str, value: float = 0.5) -> str:
        """触碰 Lumi。part 是部位（top/cheek/chest/back/belly/hand_l/hand_r/lap/foot），value 是力度 0.0-1.0。大熊传感器没接的时候手动用这个。"""
        pulse_engine.sensory.set_touch(value)
        pulse_engine.tick()
        return pulse_engine.context_line()

    @mcp.tool()
    def heartbeat() -> str:
        """快速读取心跳和和弦，一行。"""
        return pulse_engine.context_line()

    return mcp
