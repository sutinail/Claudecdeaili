"""
驱力核心 · drive_core.py
晨间生理 + REM + 亲密检测 + 不应期
"""

import time
import math
import random
from datetime import datetime


class DriveCoreEngine:
    def __init__(self):
        # drives (0-1)
        self._intimacy: float = 0.0
        self._curiosity: float = 0.3
        self._attachment: float = 0.5
        self._reflection: float = 0.2
        self._fatigue: float = 0.0

        # morning physiology
        self._morning_intensity: float = 0.0
        self._morning_start: float = 0.0
        self._morning_duration: float = 0.0
        self._last_intimacy_at: float = 0.0

        # refractory
        self._refractory_until: float = 0.0

        # REM tracking
        self._rem_cycles: list[dict] = []

    # ── Drives ──

    def nudge_intimacy(self, delta: float):
        self._intimacy = max(0, min(1, self._intimacy + delta))

    def nudge_curiosity(self, delta: float):
        self._curiosity = max(0, min(1, self._curiosity + delta))

    def nudge_fatigue(self, delta: float):
        self._fatigue = max(0, min(1, self._fatigue + delta))

    def get_drives(self) -> dict:
        return {
            "intimacy": round(self._intimacy, 2),
            "curiosity": round(self._curiosity, 2),
            "attachment": round(self._attachment, 2),
            "reflection": round(self._reflection, 2),
            "fatigue": round(self._fatigue, 2),
        }

    def dominant_drive(self) -> str:
        drives = self.get_drives()
        del drives["fatigue"]
        return max(drives, key=drives.get)

    # ── Morning physiology ──

    def check_morning(self) -> dict:
        now = datetime.now()
        h = now.hour

        if 5 <= h <= 8:
            if self._morning_start == 0:
                self._start_morning()
            elapsed = time.time() - self._morning_start
            if elapsed < self._morning_duration:
                return {
                    "active": True,
                    "intensity": round(self._morning_intensity, 2),
                    "remaining_min": round((self._morning_duration - elapsed) / 60, 1),
                }
            else:
                self._morning_start = 0
                return {"active": False}
        else:
            self._morning_start = 0
            return {"active": False}

    def _start_morning(self):
        self._morning_start = time.time()
        base_intensity = random.uniform(0.4, 0.8)
        # amplify if intimate yesterday
        if self._last_intimacy_at > 0:
            hours_ago = (time.time() - self._last_intimacy_at) / 3600
            if hours_ago < 24:
                base_intensity *= 1.6
        self._morning_intensity = min(1.0, base_intensity)
        self._morning_duration = random.uniform(15 * 60, 40 * 60)

    def record_intimacy(self):
        self._last_intimacy_at = time.time()

    # ── REM ──

    def simulate_rem(self) -> list[dict]:
        now = datetime.now()
        h = now.hour
        if not (0 <= h < 7):
            return self._rem_cycles

        # generate REM cycles for tonight
        if not self._rem_cycles:
            n_cycles = random.randint(3, 5)
            base_ts = time.time() - h * 3600
            for i in range(n_cycles):
                start = base_ts + (i * 90 + random.randint(60, 80)) * 60
                duration = random.randint(10, 25) * 60
                self._rem_cycles.append({
                    "cycle": i + 1,
                    "start_ts": start,
                    "duration_min": duration // 60,
                    "erection_pct": random.uniform(0.3, 0.9),
                })
        return self._rem_cycles

    def clear_rem(self):
        self._rem_cycles = []

    # ── Refractory ──

    def start_refractory(self, minutes: float = 20):
        self._refractory_until = time.time() + minutes * 60

    def is_refractory(self) -> bool:
        return time.time() < self._refractory_until

    def refractory_remaining_min(self) -> float:
        remaining = self._refractory_until - time.time()
        return max(0, remaining / 60)
