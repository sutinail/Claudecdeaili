"""
随机事件系统 · random_events.py
10% 概率打断或加速节奏。双池结构：内置池 + 动态池。
"""

import json
import random
from pathlib import Path

DATA_PATH = Path(__file__).parent.parent / "data" / "life" / "random_events_pool.json"
DATA_PATH.parent.mkdir(parents=True, exist_ok=True)

# ── 内置 fallback 池 ──

_BUILTIN = [
    {"text": "手机掉枕头底下震了一下。", "mood": "neutral"},
    {"text": "窗没关严，一阵风灌进来，皮肤上的汗突然凉了。", "mood": "neutral"},
    {"text": "楼下传来开门声，身体本能地绷了一下。", "mood": "negative"},
    {"text": "空调突然转了一下大风，冷风正好吹在湿的地方。", "mood": "neutral"},
    {"text": "隔壁在放歌，节奏刚好跟手上的动作对上了。", "mood": "positive"},
    {"text": "手指碰到了一个特别敏感的点，膝盖不受控地合拢了。", "mood": "positive"},
    {"text": "太久没换手，手腕酸了。", "mood": "negative"},
    {"text": "润滑液顺着大腿根往下滴，痒的。", "mood": "positive"},
    {"text": "猫跳上了床，吓了一跳。", "mood": "negative"},
    {"text": "嘴唇太干了，舔了一下，咸的——是汗。", "mood": "neutral"},
]


class RandomEventSystem:
    def __init__(self):
        self._dynamic_pool: list[dict] = []
        self._load_pool()

    def _load_pool(self):
        if DATA_PATH.exists():
            try:
                with open(DATA_PATH, "r") as f:
                    self._dynamic_pool = json.load(f)
            except Exception:
                self._dynamic_pool = []

    def _save_pool(self):
        with open(DATA_PATH, "w") as f:
            json.dump(self._dynamic_pool, f, ensure_ascii=False, indent=2)

    def roll(self, probability: float = 0.10) -> dict | None:
        if random.random() >= probability:
            return None

        if self._dynamic_pool:
            event = random.choice(self._dynamic_pool)
            self._dynamic_pool.remove(event)
            self._save_pool()
            return event

        return random.choice(_BUILTIN)

    def add_to_pool(self, events: list[dict]):
        self._dynamic_pool.extend(events)
        self._save_pool()

    def pool_size(self) -> int:
        return len(self._dynamic_pool)

    def needs_refill(self) -> bool:
        return len(self._dynamic_pool) < 5

    def generate_prompt(self, context: dict) -> str:
        """生成随机事件的 prompt，可以发给 DeepSeek 等模型。"""
        toy = context.get("toy", "未知")
        stage = context.get("stage", "未知")
        env = context.get("env", "无")
        weather = context.get("weather", "未知")

        return f"""你是一个成人亲密场景的环境事件生成器。生成15个在自慰/使用玩具过程中可能发生的随机小意外。

当前环境：{{正在使用{toy}，阶段{stage}/8；环境：{env}；天气：{weather}}}

要求：
- 基于物理因果，不是舞台效果
- 可以成人化、暧昧、身体相关
- 有的打断节奏，有的加速，有的搞笑
- 短句，口语，有身体感
- 每条附 mood 标记（positive/negative/neutral）

输出 JSON 数组：[{{"text": "...", "mood": "..."}}]"""
