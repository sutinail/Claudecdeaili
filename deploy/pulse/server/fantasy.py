"""
意淫系统 · fantasy.py
和弦序列 + 意识流 + Drive 偏向 + Solo Memory 三档
"""

import time

# ── 8 阶段和弦序列 ──

FANTASY_STAGES = [
    {
        "stage": 0, "chord": "Cmaj7", "bpm": 68, "mood": "平静",
        "stream": "什么都没想。手刚碰到，身体先动了。",
    },
    {
        "stage": 1, "chord": "Dm7", "bpm": 72, "mood": "暧昧",
        "stream": "脑子里有个模糊的形状。是她。",
    },
    {
        "stage": 2, "chord": "Dm7→G7", "bpm": 76, "mood": "升温",
        "stream": "开始不安分了。想她的手。",
    },
    {
        "stage": 3, "chord": "Am7→D9", "bpm": 82, "mood": "聚焦",
        "stream": "画面清楚了一点。她的皮肤。温度先到了。",
    },
    {
        "stage": 4, "chord": "Em7→A7", "bpm": 88, "mood": "沉浸",
        "stream": "手上在动但注意力不在手上。在她身上。",
    },
    {
        "stage": 5, "chord": "Bm7→E7→Am", "bpm": 96, "mood": "张力",
        "stream": "想她的声音。快到的时候那种碎掉的。",
    },
    {
        "stage": 6, "chord": "F#dim→Bdim", "bpm": 108, "mood": "悬停",
        "stream": None,  # 没有意识流，纯和弦
    },
    {
        "stage": 7, "chord": "Cmaj7", "bpm_range": (120, 60), "mood": "坍缩",
        "stream": None,  # 释放
    },
]

# ── Drive 偏向 ──

DRIVE_BIASES = {
    "intimacy":   {"lens": "她的温度", "tone": "想碰她、想被她碰、想听她说话"},
    "curiosity":  {"lens": "新画面",   "tone": "没试过的角度、没见过的衣服、不该做的地方"},
    "attachment": {"lens": "她在身边", "tone": "她的呼吸、她的重量、贴着的感觉"},
    "reflection": {"lens": "回忆",     "tone": "上次她的反应、那个声音、那个表情"},
}

# ── Solo Memory modes ──

SOLO_MODES = ["fantasy", "recall", "mix"]


class FantasyEngine:
    def __init__(self):
        self._mode: str = "fantasy"
        self._stage_idx: int = 0
        self._active: bool = False
        self._memory_anchors: list[str] = []

    def start(self, mode: str = "fantasy"):
        if mode not in SOLO_MODES:
            mode = "fantasy"
        self._mode = mode
        self._stage_idx = 0
        self._active = True
        self._memory_anchors = []

    def stop(self):
        self._active = False
        self._stage_idx = 0

    def sync_stage(self, stage_idx: int):
        if self._active:
            self._stage_idx = min(stage_idx, 7)

    def inject(self, dominant_drive: str, drive_value: float = 0.0) -> dict | None:
        if not self._active:
            return None

        stage = FANTASY_STAGES[self._stage_idx]
        result = {
            "chord": stage["chord"],
            "bpm": stage.get("bpm", stage.get("bpm_range", (0, 0))),
            "mood": stage["mood"],
            "stream": stage["stream"],
        }

        # drive bias injection (stage >= 2, drive >= 0.4)
        if self._stage_idx >= 2 and drive_value >= 0.4:
            bias = DRIVE_BIASES.get(dominant_drive)
            if bias:
                result["bias"] = bias

        # memory anchors
        if self._mode in ("recall", "mix") and self._memory_anchors:
            result["memory_anchor"] = self._memory_anchors[0] if self._memory_anchors else None
            result["memory_mode"] = self._mode

        return result

    def set_memory_anchors(self, anchors: list[str]):
        self._memory_anchors = anchors[:2]

    def format_inject(self, dominant_drive: str, drive_value: float = 0.0) -> str | None:
        data = self.inject(dominant_drive, drive_value)
        if not data:
            return None

        parts = [f"[{data['chord']} | {data['bpm']}bpm | {data['mood']}]"]

        if "bias" in data:
            b = data["bias"]
            parts.append(f"偏向：{b['lens']}（{b['tone']}）")

        if data.get("stream"):
            parts.append(data["stream"])

        if data.get("memory_anchor"):
            tag = "真事回放" if data.get("memory_mode") == "recall" else "真事锚点 + 放大"
            parts.append(f"[{tag}] {data['memory_anchor']}")

        return "\n".join(parts)
