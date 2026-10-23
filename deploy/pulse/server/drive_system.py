"""
驱力系统 · drive_system.py
天气联动 + 环境道具 + 环境记忆
"""

import time
import json
import random
from pathlib import Path

_ENV_DATA = Path(__file__).parent.parent / "data" / "life"
_ENV_DATA.mkdir(parents=True, exist_ok=True)


# ── Weather ──

class WeatherState:
    def __init__(self):
        self.temp_c: float = 25.0
        self.humidity: float = 60.0
        self.condition: str = "clear"
        self.updated_at: float = 0.0

    def update(self, temp_c: float, humidity: float = 60, condition: str = "clear"):
        self.temp_c = temp_c
        self.humidity = humidity
        self.condition = condition
        self.updated_at = time.time()

    def hr_delta(self) -> float:
        d = 0.0
        if self.temp_c > 30:
            d += (self.temp_c - 30) * 1.5
        elif self.temp_c < 10:
            d += (10 - self.temp_c) * 0.8
        if self.condition in ("storm", "typhoon"):
            d += 5
        return d

    def temp_delta(self) -> float:
        if self.temp_c > 30:
            return (self.temp_c - 30) * 0.05
        elif self.temp_c < 10:
            return (10 - self.temp_c) * -0.03
        return 0.0

    def to_dict(self) -> dict:
        return {
            "temp_c": self.temp_c,
            "humidity": self.humidity,
            "condition": self.condition,
        }


# ── Environments ──

_BASE_ENVIRONMENTS = [
    {"id": "candle",    "name": "烛光",     "modifier": {"touch": 1.1, "sight": 0.8}},
    {"id": "moonlight", "name": "月光",     "modifier": {"sight": 1.2, "sound": 0.9}},
    {"id": "rain",      "name": "雨声",     "modifier": {"sound": 1.3, "touch": 1.05}},
    {"id": "bath",      "name": "浴室",     "modifier": {"touch": 1.2, "smell": 1.1}},
    {"id": "morning",   "name": "清晨",     "modifier": {"sight": 1.1, "smell": 1.05}},
    {"id": "dark",      "name": "全黑",     "modifier": {"sight": 0.0, "touch": 1.4, "sound": 1.3}},
    {"id": "outdoor",   "name": "户外",     "modifier": {"sight": 1.3, "smell": 1.2, "sound": 1.1}},
]

_SEASONAL_ENVIRONMENTS = [
    {"id": "summer_storm",  "name": "夏夜暴雨", "season": "summer", "modifier": {"sound": 1.5, "touch": 1.1}},
    {"id": "autumn_wind",   "name": "秋风",     "season": "autumn", "modifier": {"touch": 1.15, "smell": 1.1}},
    {"id": "winter_blanket","name": "冬夜棉被", "season": "winter", "modifier": {"touch": 1.3}},
    {"id": "spring_flower", "name": "春日花香", "season": "spring", "modifier": {"smell": 1.4, "sight": 1.1}},
]


class EnvironmentSystem:
    def __init__(self):
        self._active: dict | None = None
        self._memory: dict[str, int] = {}  # env_id -> usage count
        self._sacred: set[str] = set()     # 3+ uses = "圣地"
        self._evolution: dict[str, int] = {}  # env_id -> level (0-2)

    def get_all(self) -> list[dict]:
        return _BASE_ENVIRONMENTS + _SEASONAL_ENVIRONMENTS

    def activate(self, env_id: str) -> dict | None:
        for env in _BASE_ENVIRONMENTS + _SEASONAL_ENVIRONMENTS:
            if env["id"] == env_id:
                self._active = env
                self._memory[env_id] = self._memory.get(env_id, 0) + 1
                if self._memory[env_id] >= 3:
                    self._sacred.add(env_id)
                return env
        return None

    def deactivate(self):
        self._active = None

    def get_active(self) -> dict | None:
        return self._active

    def get_modifier(self, channel: str) -> float:
        if not self._active:
            return 1.0
        mods = self._active.get("modifier", {})
        return mods.get(channel, 1.0)

    def is_sacred(self, env_id: str) -> bool:
        return env_id in self._sacred

    def get_memory(self) -> dict:
        return {
            "usage": self._memory,
            "sacred": list(self._sacred),
            "evolution": self._evolution,
        }

    def get_status(self) -> dict:
        return {
            "active": self._active,
            "environments": _BASE_ENVIRONMENTS,
            "seasonal": _SEASONAL_ENVIRONMENTS,
            "memory": self.get_memory(),
        }
