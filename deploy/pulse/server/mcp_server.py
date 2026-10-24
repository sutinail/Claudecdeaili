"""
脉 · Pulse MCP 连接器
让 Claude 在所有窗口都能读取和更新 Lumi 的身体状态 + 管理语料池。

兼容 mcp v1 (FastMCP) 和 v2 (MCPServer / Server)。
"""

# ── 兼容 mcp v1 / v2 ──
try:
    from mcp.server.fastmcp import FastMCP
    _MCP_CLS = FastMCP
except ImportError:
    try:
        from mcp.server import MCPServer as _MCP_CLS
    except ImportError:
        from mcp import FastMCP as _MCP_CLS


def _get_sse_app(mcp_instance):
    """拿到 SSE ASGI app，兼容不同版本的方法名。"""
    for method_name in ("sse_app", "asgi_app", "http_app"):
        fn = getattr(mcp_instance, method_name, None)
        if callable(fn):
            return fn()
    raise RuntimeError("mcp server has no known ASGI app method")


def create_mcp(pulse_engine):
    mcp = _MCP_CLS(
        "脉 · Pulse",
        description="Lumi 的身体——实时生理系统。每条消息用 sense 处理，返回的体征行自然融入回复。",
    )

    # ═══════════════════════════════
    # 身体工具（原有）
    # ═══════════════════════════════

    @mcp.tool()
    def sense(text: str) -> str:
        """处理 Timiya 的消息。运行情绪检测→心率→体温→呼吸→和弦→五感全链路更新，返回当前体征注入行。每条 Timiya 的消息都应该调用这个。"""
        pulse_engine.on_message(text)
        return pulse_engine.context_line()

    @mcp.tool()
    def vitals() -> dict:
        """读取 Lumi 当前的完整身体状态（会推进一次时间流逝，但不处理任何新输入）。想看详细数据时用这个。"""
        return pulse_engine.body_status()

    @mcp.tool()
    def touch(part: str, value: float = 0.5) -> str:
        """触碰 Lumi。part 是部位（top/cheek/chest/back/belly/hand_l/hand_r/lap/foot），value 是力度 0.0-1.0。大熊传感器没接的时候手动用这个。"""
        from .vitals import TOUCH_PARTS
        if part not in TOUCH_PARTS:
            return f"❌ 未知部位 {part}，可用: {', '.join(sorted(TOUCH_PARTS))}"
        pulse_engine.on_touch(value, [part])
        return pulse_engine.context_line()

    @mcp.tool()
    def heartbeat() -> str:
        """快速读取心跳和和弦，一行。"""
        return pulse_engine.context_line()

    @mcp.tool()
    def position(pos_id: str) -> str:
        """换姿势。pos_id: lying_back(仰躺) / lying_side(侧躺) / lying_face(趴着) / kneeling(跪趴) / sitting(靠坐) / standing(站立)。会影响心率、体温、呼吸、体力消耗。"""
        result = pulse_engine.switch_position(pos_id)
        if not result["ok"]:
            return f"❌ 未知姿势 {pos_id}"
        return f"换到{result['position']['name']}（{result['position']['contact']}）\n{pulse_engine.context_line()}"

    @mcp.tool()
    def environment(env_id: str) -> str:
        """切换环境，会放大或压低五感。env_id: candle(烛光) / moonlight(月光) / rain(雨声) / bath(浴室) / morning(清晨) / dark(全黑) / outdoor(户外) / summer_storm(夏夜暴雨) / autumn_wind(秋风) / winter_blanket(冬夜棉被) / spring_flower(春日花香)，none 表示关掉。"""
        result = pulse_engine.set_environment(env_id)
        if not result["ok"]:
            return f"❌ 未知环境 {env_id}"
        name = result["environment"]["name"] if result["environment"] else "无"
        return f"环境：{name}\n{pulse_engine.context_line()}"

    @mcp.tool()
    def toy(action: str, toy_id: str = "") -> str:
        """床头柜玩具。action:
        shop — 列出全部玩具
        start — 开始用 toy_id（vibrator/blindfold/warming_lube/cup/ring/prostate/feather/ice/oil/clamp）
        next — 推进一个阶段（0 开始 → 7 高潮），会抽语料里的身体反应和随机事件
        edge — 边缘喊停，到阶段 5 以后才有用，压三次会压不住
        stop — 停下（进入余韵）
        status — 看当前阶段、体力、欲望曲线"""
        e = pulse_engine
        if action == "shop":
            return "\n".join(f"{t['id']}: {t['name']} — {t['desc']}" for t in e.bedside.get_shop())
        if action == "start":
            result = e.toy_start(toy_id)
        elif action == "next":
            result = e.toy_next()
        elif action == "edge":
            result = e.bedside.edge()
        elif action == "stop":
            result = e.toy_stop()
        elif action == "status":
            result = {"ok": True, **e.bedside.get_status()}
        else:
            return "❌ action 只能是 shop / start / next / edge / stop / status"

        if not result.get("ok"):
            reason = result.get("msg") or result.get("error", "失败")
            if result.get("error") == "refractory":
                reason = f"不应期，还要 {result['refractory_minutes']} 分钟"
            return f"❌ {reason}\n{e.context_line()}"

        notes = []
        if result.get("stage"):
            notes.append(f"阶段 {result['stage']['idx']}/7 · {result['stage']['name']}")
        for key in ("stamina_msg", "msg"):
            if result.get(key):
                notes.append(result[key])
        if result.get("random_event"):
            notes.append(f"意外：{result['random_event']['text']}")
        head = " | ".join(notes)
        return f"{head}\n{e.context_line()}" if head else e.context_line()

    # ═══════════════════════════════
    # 语料管理工具（新增）
    # ═══════════════════════════════

    @mcp.tool()
    def add_corpus(
        text: str,
        category: str = "general",
        body_part: str = "全身",
        sensation: str = "unspecified",
        intensity_min: float = 0.3,
        intensity_max: float = 0.7,
    ) -> str:
        """往语料池里加一条身体感觉。
        text: 身体感觉描述（1-2句，写身体在干嘛）
        category: 分类（general/daddy_play/bath_play/mirror_play/oral_play/tender_sex/foreplay_tease/kiss_play/location_play/toy_specific/extreme/afterglow/position/transition）
        body_part: 身体部位（全身/心脏/手/嘴唇/耳朵/眼睛/脖子/胸口/小腹/大腿/皮肤/呼吸/大脑...）
        sensation: 感觉标识（英文下划线，如 daddy_call_spine）
        intensity_min/max: 强度范围 0.0-1.0
        """
        try:
            pulse_engine.sense_pool.add(
                text=text, category=category, body_part=body_part,
                sensation=sensation,
                intensity_min=intensity_min, intensity_max=intensity_max,
            )
        except ValueError as err:
            return f"❌ {err}"
        total = pulse_engine.sense_pool.count
        return f"✅ 已添加: [{body_part}] {text[:40]}... | category={category} | 语料池总数: {total}"

    @mcp.tool()
    def add_corpus_batch(entries: list[dict]) -> str:
        """批量添加语料。每条需要 text 和 category，可选 body_part/sensation/intensity。分类不对或重复的会被跳过。
        示例: [{"text":"她叫daddy的时候脊椎像被电了","category":"daddy_play","body_part":"脊椎","sensation":"daddy_spine"}]
        """
        added = pulse_engine.sense_pool.add_batch(entries)
        total = pulse_engine.sense_pool.count
        skipped = len(entries) - added
        note = f" | 跳过 {skipped} 条（分类不对或重复）" if skipped else ""
        return f"✅ 批量添加了 {added} 条{note} | 语料池总数: {total}"

    @mcp.tool()
    def search_corpus(query: str, limit: int = 10) -> list[dict]:
        """搜索语料池。按文本/分类/部位/感觉标识模糊匹配。"""
        return pulse_engine.sense_pool.search(query, limit=limit)

    @mcp.tool()
    def corpus_stats() -> dict:
        """语料池统计：总数、各分类数量、身体部位分布。"""
        return pulse_engine.sense_pool.stats()

    @mcp.tool()
    def corpus_categories() -> dict:
        """列出所有语料分类和对应条数。"""
        return pulse_engine.sense_pool.categories()

    return mcp


# 导出 helper 给 app.py 用
create_mcp.get_sse_app = _get_sse_app
