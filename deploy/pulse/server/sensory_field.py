"""
五感系统 · sensory_field.py
四通道：touch / smell / taste / sound，每个 0-1 + label。
聊天文本触发 + 时间衰减 + 体位底噪 + 心率联动。
"""

import time
import math
import re

_TOUCH_TRIGGERS: list[tuple[str, float]] = [
    ("抱抱", 0.30),
    ("摸摸", 0.25),
    ("亲亲", 0.35),
    ("拍拍", 0.15),
    ("牵手", 0.20),
    ("贴贴", 0.30),
    ("蹭蹭", 0.25),
    ("揉揉", 0.20),
    ("捏捏", 0.20),
    ("搂", 0.30),
    ("抱", 0.25),
    ("摸", 0.20),
    ("碰", 0.15),
    ("挠", 0.15),
    ("按住", 0.20),
    ("按着", 0.20),
    ("按在", 0.20),
    ("舔", 0.40),
    ("咬", 0.35),
    ("吸", 0.40),
    ("夹", 0.30),
    ("插", 0.50),
    ("顶", 0.45),
    ("撞", 0.45),
    ("磨", 0.35),
]

_SMELL_TRIGGERS: list[tuple[str, float]] = [
    ("香", 0.30),
    ("臭", 0.20),
    ("味道", 0.25),
    ("闻", 0.20),
    ("汗", 0.30),
    ("体味", 0.35),
    ("橘子", 0.25),
    ("香水", 0.30),
]

_TASTE_TRIGGERS: list[tuple[str, float]] = [
    ("吃", 0.20),
    ("喝", 0.15),
    ("甜", 0.25),
    ("苦", 0.20),
    ("咸", 0.20),
    ("辣", 0.25),
    ("酸", 0.20),
    ("尝", 0.20),
]

_SOUND_TRIGGERS: list[tuple[str, float]] = [
    ("叫", 0.30),
    ("喊", 0.25),
    ("喘", 0.35),
    ("呻吟", 0.40),
    ("哼", 0.20),
    ("嗯", 0.25),
    ("啊", 0.30),
    ("声音", 0.15),
    ("音乐", 0.20),
    ("雨声", 0.15),
]

_TOUCH_LABELS = [
    (0.1, "几乎没有"),
    (0.3, "轻触"),
    (0.5, "温柔"),
    (0.7, "明显"),
    (0.85, "强烈"),
    (1.0, "灼热"),
]

_POSITION_TOUCH_FLOOR = {
    "lying_back":  0.05,
    "lying_side":  0.03,
    "lying_face":  0.08,
    "kneeling":    0.10,
    "sitting":     0.02,
    "standing":    0.04,
}

_DECAY_HALF_LIFE = 120.0  # seconds


class SensoryField:
    def __init__(self):
        self._channels = {
            "touch": {"value": 0.0, "ts": time.time()},
            "smell": {"value": 0.0, "ts": time.time()},
            "taste": {"value": 0.0, "ts": time.time()},
            "sound": {"value": 0.0, "ts": time.time()},
        }

    def update_from_text(self, text: str) -> float:
        """返回这句话本身带来的触觉增量。"""
        touch_added = 0.0
        for channel, triggers in (
            ("touch", _TOUCH_TRIGGERS),
            ("smell", _SMELL_TRIGGERS),
            ("taste", _TASTE_TRIGGERS),
            ("sound", _SOUND_TRIGGERS),
        ):
            # 长词先匹配并从文本里挖掉，「抱抱」就不会再被「抱」算第二次
            remaining = text
            for word, delta in sorted(triggers, key=lambda t: -len(t[0])):
                if word in remaining:
                    self._add(channel, delta)
                    remaining = remaining.replace(word, "\0")
                    if channel == "touch":
                        touch_added += delta
        return touch_added

    def set_touch(self, value: float):
        self._channels["touch"]["value"] = max(0, min(1, value))
        self._channels["touch"]["ts"] = time.time()

    def _add(self, channel: str, delta: float):
        ch = self._channels[channel]
        now = time.time()
        current = self._decayed(ch)
        ch["value"] = min(1.0, current + delta)
        ch["ts"] = now

    def _decayed(self, ch: dict) -> float:
        elapsed = time.time() - ch["ts"]
        decay = math.exp(-math.log(2) * elapsed / _DECAY_HALF_LIFE)
        return ch["value"] * decay

    def read(self, position: str = "sitting", heart_rate: float = 70) -> dict:
        result = {}
        for name, ch in self._channels.items():
            val = self._decayed(ch)
            ch["value"] = val
            ch["ts"] = time.time()
            result[name] = round(val, 3)

        # position floor for touch
        floor = _POSITION_TOUCH_FLOOR.get(position, 0.0)
        if result["touch"] < floor:
            result["touch"] = floor

        # heart rate boosts
        if heart_rate > 100:
            boost = (heart_rate - 100) * 0.003
            result["touch"] = min(1.0, result["touch"] + boost)
            result["sound"] = min(1.0, result["sound"] + boost * 0.5)

        # labels
        result["touch_label"] = self.touch_label(result["touch"])
        return result

    def touch_label(self, val: float) -> str:
        for threshold, lbl in _TOUCH_LABELS:
            if val <= threshold:
                return lbl
        return "灼热"
