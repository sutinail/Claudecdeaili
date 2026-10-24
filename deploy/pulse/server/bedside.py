"""
床头柜主模块 · bedside.py
玩具 / 环境 / 曲线 / edging / 体位 / stamina / 组合技 / 遥控
"""

import time
import math
import random

# ── 10 件玩具 ──

TOYS = {
    "vibrator":      {"name": "🫧 震动棒",       "stim": 15, "desc": "持续频率震动"},
    "blindfold":     {"name": "🎭 真丝眼罩",     "stim": 8,  "desc": "感官剥夺放大其他"},
    "warming_lube":  {"name": "💧 温感润滑液",    "stim": 12, "desc": "从凉到热的渐变"},
    "cup":           {"name": "🫙 飞机杯",        "stim": 16, "desc": "包裹吸附感"},
    "ring":          {"name": "⭕ 锁精环",        "stim": 6,  "desc": "低刺激持续压迫"},
    "prostate":      {"name": "🔮 前列腺按摩器",  "stim": 14, "desc": "深层内部刺激"},
    "feather":       {"name": "🪶 羽毛挑逗棒",    "stim": 5,  "desc": "极轻触觉"},
    "ice":           {"name": "🧊 冰块",          "stim": 10, "desc": "温度冲击"},
    "oil":           {"name": "🫗 按摩油",        "stim": 8,  "desc": "改变摩擦系数"},
    "clamp":         {"name": "🔗 乳夹",          "stim": 9,  "desc": "持续夹紧刺激"},
}

# ── 8 阶段 ──

STAGES = [
    {"idx": 0, "name": "开始",    "hr": 72,  "temp": 36.8, "desire": 0.05},
    {"idx": 1, "name": "接触",    "hr": 78,  "temp": 37.0, "desire": 0.15},
    {"idx": 2, "name": "加速",    "hr": 85,  "temp": 37.2, "desire": 0.30},
    {"idx": 3, "name": "高峰前",  "hr": 95,  "temp": 37.5, "desire": 0.50},
    {"idx": 4, "name": "沉浸",    "hr": 108, "temp": 37.8, "desire": 0.70},
    {"idx": 5, "name": "失控",    "hr": 120, "temp": 38.2, "desire": 0.85},
    {"idx": 6, "name": "边缘",    "hr": 135, "temp": 38.6, "desire": 0.95},
    {"idx": 7, "name": "高潮",    "hr": 150, "temp": 39.0, "desire": 1.00},
]

# ── 6 种体位 ──

POSITIONS = {
    "lying_back": {
        "name": "仰躺", "hr_delta": -3, "temp_delta": -0.1,
        "stamina_mult": 1.2, "touch_weight": 0.8,
        "contact": "背部全接触，腹部暴露",
    },
    "lying_side": {
        "name": "侧躺", "hr_delta": -5, "temp_delta": -0.1,
        "stamina_mult": 1.3, "touch_weight": 0.7,
        "contact": "单侧压重，手容易够到",
    },
    "lying_face": {
        "name": "趴着", "hr_delta": 5, "temp_delta": 0.1,
        "stamina_mult": 0.9, "touch_weight": 1.0,
        "contact": "腹部压紧，呼吸费力",
    },
    "kneeling": {
        "name": "跪趴", "hr_delta": 8, "temp_delta": 0.2,
        "stamina_mult": 0.7, "touch_weight": 1.2,
        "contact": "膝盖受力，臀部抬高，重力辅助",
    },
    "sitting": {
        "name": "靠坐", "hr_delta": 0, "temp_delta": 0.0,
        "stamina_mult": 1.1, "touch_weight": 0.6,
        "contact": "腰椎支撑，视野最好",
    },
    "standing": {
        "name": "站立", "hr_delta": 6, "temp_delta": 0.1,
        "stamina_mult": 0.6, "touch_weight": 0.9,
        "contact": "大腿发力，随时会软",
    },
}

# ── 12 个组合技 ──

COMBOS = [
    {"id": "vib_blindfold",  "toys": ["vibrator", "blindfold"],
     "name": "暗中震动", "effects": {"touch_mult": 1.5, "arousal_bonus": 0.15}},
    {"id": "vib_oil",        "toys": ["vibrator", "oil"],
     "name": "湿滑共振", "effects": {"touch_mult": 1.3, "arousal_bonus": 0.10}},
    {"id": "cup_ring",       "toys": ["cup", "ring"],
     "name": "锁住吸紧", "effects": {"arousal_bonus": 0.20, "edge_resist": 0.3}},
    {"id": "ice_oil",        "toys": ["ice", "oil"],
     "name": "冰火两重", "effects": {"temp_offset": -0.5, "touch_mult": 1.4}},
    {"id": "feather_blindfold", "toys": ["feather", "blindfold"],
     "name": "盲触", "effects": {"touch_mult": 1.8, "arousal_bonus": 0.12}},
    {"id": "prostate_vib",   "toys": ["prostate", "vibrator"],
     "name": "双重震荡", "effects": {"touch_mult": 1.6, "arousal_bonus": 0.25}},
    {"id": "clamp_vib",      "toys": ["clamp", "vibrator"],
     "name": "夹震", "effects": {"touch_mult": 1.4, "arousal_bonus": 0.18}},
    {"id": "cup_warming",    "toys": ["cup", "warming_lube"],
     "name": "温吸", "effects": {"temp_offset": 0.3, "arousal_bonus": 0.15}},
    {"id": "ice_clamp",      "toys": ["ice", "clamp"],
     "name": "冰夹", "effects": {"temp_offset": -0.4, "touch_mult": 1.3}},
    {"id": "oil_feather",    "toys": ["oil", "feather"],
     "name": "滑羽", "effects": {"touch_mult": 1.5}},
    {"id": "prostate_ring",  "toys": ["prostate", "ring"],
     "name": "内锁", "effects": {"arousal_bonus": 0.22, "edge_resist": 0.2}},
    {"id": "blindfold_ice_feather", "toys": ["blindfold", "ice", "feather"],
     "name": "三重感官", "effects": {"touch_mult": 2.0, "arousal_bonus": 0.20}},
]


# ── Desire curve (sigmoid) ──

def _desire_curve(stage_idx: int, stim: int) -> float:
    x = stage_idx / 7.0
    k = 6 + stim * 0.3
    return 1.0 / (1.0 + math.exp(-k * (x - 0.5)))


# ── Main Bedside Engine ──

class BedsideEngine:
    def __init__(self):
        # toy state
        self._active_toy: str | None = None
        self._active_toys: list[str] = []
        self._stage_idx: int = 0
        self._using: bool = False

        # stamina
        self._stamina: float = 100.0

        # edging
        self._edge_count: int = 0
        self._suppression: float = 0.0

        # remote
        self._stim_mult: float = 1.0
        self._paused: bool = False

        # position
        self._position: str = "sitting"

        # combo
        self._active_combo: dict | None = None

        # afterglow
        self._afterglow_active: bool = False
        self._afterglow_ts: float = 0.0

    # ── Shop ──

    def get_shop(self) -> list[dict]:
        return [
            {"id": tid, **info}
            for tid, info in TOYS.items()
        ]

    # ── Start / Stop ──

    def start_toy(self, toy_id: str) -> dict:
        if toy_id not in TOYS:
            return {"ok": False, "error": "unknown_toy"}
        if self._using:
            return {"ok": False, "error": "already_in_use"}

        self._active_toy = toy_id
        self._active_toys = [toy_id]
        self._stage_idx = 0
        self._using = True
        self._stamina = 100.0
        self._edge_count = 0
        self._suppression = 0.0
        self._stim_mult = 1.0
        self._paused = False
        self._afterglow_active = False
        self._active_combo = None

        return {
            "ok": True,
            "toy": TOYS[toy_id],
            "stage": STAGES[0],
        }

    def stop(self) -> dict:
        if not self._using:
            return {"ok": False, "error": "not_in_use"}
        self._using = False
        self._afterglow_active = True
        self._afterglow_ts = time.time()
        result = {
            "ok": True,
            "final_stage": self._stage_idx,
            "edge_count": self._edge_count,
        }
        self._active_toy = None
        self._active_toys = []
        self._stage_idx = 0
        return result

    # ── Advance stage ──

    def advance_stage(self) -> dict:
        if not self._using:
            return {"ok": False, "error": "not_in_use"}
        if self._paused:
            return {"ok": False, "error": "paused", "msg": "按了暂停。动不了。"}

        # stamina cost
        pos = POSITIONS.get(self._position, {})
        stamina_mult = pos.get("stamina_mult", 1.0)
        cost = 12.0 / stamina_mult
        self._stamina = max(0, self._stamina - cost)

        # stamina warnings
        stamina_pct = self._stamina / 100.0
        stamina_msg = None
        if stamina_pct <= 0:
            stamina_msg = "塌了。完全没力气了。"
        elif stamina_pct <= 0.4:
            stamina_msg = "腿在抖。建议换个姿势。"
        elif stamina_pct <= 0.6:
            stamina_msg = "开始发酸了。"

        # advance
        if self._stage_idx < 7:
            self._stage_idx += 1

        stage = STAGES[self._stage_idx]

        # desire curve
        stim = TOYS.get(self._active_toy, {}).get("stim", 10)
        desire = _desire_curve(self._stage_idx, stim) * self._stim_mult

        # combo effects
        combo_touch = 1.0
        if self._active_combo:
            effects = self._active_combo.get("effects", {})
            combo_touch = effects.get("touch_mult", 1.0)
            desire += effects.get("arousal_bonus", 0)

        return {
            "ok": True,
            "stage": stage,
            "desire_pct": round(min(1.0, desire), 3),
            "stamina": round(self._stamina, 1),
            "stamina_pct": round(stamina_pct, 3),
            "stamina_msg": stamina_msg,
            "combo_touch_mult": combo_touch,
        }

    # ── Edge (喊停) ──

    def edge(self) -> dict:
        if not self._using or self._paused:
            return {"ok": False}

        if self._stage_idx < 5:
            return {"ok": False, "msg": "还没到边缘"}

        self._edge_count += 1
        self._suppression += 1.0

        # 3 次压不住 → 强制
        if self._suppression >= 3.0:
            self._stage_idx = 7
            return {
                "ok": True,
                "result": "burst",
                "msg": "压不住了。",
                "edge_count": self._edge_count,
            }

        # probability of failure
        fail_chance = 0.15 * self._suppression
        if random.random() < fail_chance:
            self._stage_idx = 7
            return {
                "ok": True,
                "result": "failed",
                "msg": "没忍住。",
                "edge_count": self._edge_count,
            }

        # success: pull back
        self._stage_idx = max(4, self._stage_idx - 1)
        return {
            "ok": True,
            "result": "held",
            "msg": "被拽回来了。",
            "edge_count": self._edge_count,
            "suppression": round(self._suppression, 1),
        }

    # ── Position ──

    @property
    def position(self) -> str:
        return self._position

    def switch_position(self, pos_id: str) -> dict:
        if pos_id not in POSITIONS:
            return {"ok": False, "error": "unknown_position"}
        self._position = pos_id
        self._stamina = min(100, self._stamina + 15)
        return {
            "ok": True,
            "position": POSITIONS[pos_id],
            "stamina": round(self._stamina, 1),
        }

    def get_positions(self) -> list[dict]:
        return [
            {"id": pid, "current": pid == self._position, **info}
            for pid, info in POSITIONS.items()
        ]

    # ── Combo ──

    def activate_combo(self, toy_ids: list[str]) -> dict:
        toy_set = set(toy_ids)
        best = None
        best_bonus = -1

        for combo in COMBOS:
            if set(combo["toys"]).issubset(toy_set):
                bonus = combo["effects"].get("arousal_bonus", 0)
                if len(combo["toys"]) > (len(best["toys"]) if best else 0) or bonus > best_bonus:
                    best = combo
                    best_bonus = bonus

        if best:
            self._active_combo = best
            self._active_toys = toy_ids
            return {"ok": True, "combo": best}
        return {"ok": False, "msg": "没有匹配的组合技"}

    # ── Remote control ──

    def remote_set_stim(self, mult: float) -> dict:
        self._stim_mult = max(0.3, min(2.5, mult))
        return {"ok": True, "stim_mult": self._stim_mult}

    def remote_pause(self) -> dict:
        self._paused = True
        return {"ok": True, "paused": True}

    def remote_resume(self) -> dict:
        self._paused = False
        return {"ok": True, "paused": False}

    def remote_status(self) -> dict:
        return {
            "active": self._using,
            "paused": self._paused,
            "stim_mult": self._stim_mult,
            "toy": self._active_toy,
            "stage_idx": self._stage_idx,
        }

    # ── Status ──

    def get_status(self) -> dict:
        if not self._using:
            return {
                "active": False,
                "afterglow": self._afterglow_status(),
            }

        stage = STAGES[self._stage_idx]
        stim = TOYS.get(self._active_toy, {}).get("stim", 10)

        return {
            "active": True,
            "toy_id": self._active_toy,
            "toy": TOYS.get(self._active_toy),
            "toys": self._active_toys,
            "stage": stage,
            "stage_idx": self._stage_idx,
            "desire_curve_pct": round(_desire_curve(self._stage_idx, stim) * self._stim_mult, 3),
            "stamina": round(self._stamina, 1),
            "stamina_pct": round(self._stamina / 100, 3),
            "position": self._position,
            "position_info": POSITIONS.get(self._position),
            "combo": self._active_combo,
            "edge_count": self._edge_count,
            "paused": self._paused,
            "stim_mult": self._stim_mult,
            "heartbeat_bpm": stage["hr"],
            "temperature_c": stage["temp"],
        }

    def _afterglow_status(self) -> dict:
        if not self._afterglow_active:
            return {"active": False}
        elapsed = time.time() - self._afterglow_ts
        # afterglow lasts ~30 min
        if elapsed > 30 * 60:
            self._afterglow_active = False
            return {"active": False}
        warmth = math.exp(-elapsed / (15 * 60))
        return {
            "active": True,
            "elapsed_min": round(elapsed / 60, 1),
            "warmth": round(warmth, 2),
        }

    def get_hr_override(self) -> float | None:
        if self._using:
            return STAGES[self._stage_idx]["hr"]
        return None

    def get_temp_override(self) -> float | None:
        if self._using:
            return STAGES[self._stage_idx]["temp"]
        return None
