"""
心率模型 · heart_rate.py
HR = clamp(base + Δemo + Δdrive + Δweather + Δspike + Δmorning + Δposition + noise, 48, 160)
"""

import time
import math
import random
import json
import os
from pathlib import Path

from .clock import local_now

DATA_DIR = Path(__file__).parent.parent / "data" / "life" / "hr_history"
DATA_DIR.mkdir(parents=True, exist_ok=True)

# ── Perlin-like noise ──

class PerlinNoise1D:
    def __init__(self, seed=42):
        self._rng = random.Random(seed)
        self._grads = {}

    def _grad(self, i: int) -> float:
        if i not in self._grads:
            self._grads[i] = self._rng.uniform(-1, 1)
        return self._grads[i]

    def __call__(self, x: float) -> float:
        x0 = int(math.floor(x))
        x1 = x0 + 1
        t = x - x0
        fade = t * t * t * (t * (t * 6 - 15) + 10)
        g0 = self._grad(x0) * (x - x0)
        g1 = self._grad(x1) * (x - x1)
        return g0 + fade * (g1 - g0)

_noise = PerlinNoise1D()

# ── Time-based base HR ──

def _time_period() -> str:
    h = local_now().hour
    if 0 <= h < 5:
        return "deep_sleep"
    elif 5 <= h < 7:
        return "light_sleep"
    elif 7 <= h < 9:
        return "awake_lying"
    elif 9 <= h < 22:
        return "sitting"
    else:
        return "awake_lying"

_BASE_RANGES = {
    "deep_sleep":   (52, 60),
    "light_sleep":  (58, 68),
    "awake_lying":  (62, 72),
    "sitting":      (68, 78),
    "standing":     (72, 85),
}

def _base_hr() -> float:
    lo, hi = _BASE_RANGES[_time_period()]
    t = (math.sin(time.time() * 0.001) + 1) / 2
    return lo + t * (hi - lo)


# ── Emotion HR deltas ──

_EMO_DELTAS = {
    "neutral":    0,
    "happy":      3,
    "focused":    2,
    "sad":       -5,
    "scolded":   15,
    "nervous":   12,
    "startled":  20,
    "intimate":  18,
    "aroused":   25,
    "excited":   15,
    "angry":     18,
    "shy":        8,
    "touched":   10,
}

# 情绪持续多久（秒）没有被再次触发就回落到 neutral；之后由情绪底色慢慢收尾
_EMO_HOLD = {
    "startled":  60,
    "nervous":  300,
    "shy":      300,
    "happy":    600,
    "excited":  600,
    "touched":  600,
    "focused":  900,
    "scolded":  900,
    "angry":    900,
    "aroused":  900,
    "sad":     1200,
    "intimate":1200,
}

_EMO_SMOOTH_TAU = 20.0  # 秒，情绪对心率的影响按时间平滑，不再取决于调用频率


# ── Main HR Engine ──

class HeartRateEngine:
    def __init__(self):
        self._emotion: str = "neutral"
        self._emo_delta: float = 0.0
        self._emo_target: float = 0.0
        self._emotion_ts: float = time.time()
        self._undertone_delta: float = 0.0

        self._drive_intimacy: float = 0.0
        self._drive_fatigue: float = 0.0

        self._weather_temp_c: float = 25.0

        self._spike: float = 0.0
        self._spike_ts: float = 0.0

        self._morning_active: bool = False

        self._position: str = "sitting"
        self._position_deltas = {
            "lying_back": -5,
            "lying_side": -7,
            "lying_face": 5,
            "kneeling":   8,
            "sitting":    0,
            "standing":   6,
        }

        self._toy_override_hr: float | None = None

        self._last_update: float = time.time()
        self._history: list[dict] = []

    @property
    def emotion(self) -> str:
        return self._emotion

    def set_emotion(self, emo: str):
        if emo in _EMO_DELTAS:
            self._emotion = emo
            self._emo_target = _EMO_DELTAS[emo]
            self._emotion_ts = time.time()

    def set_undertone(self, delta: float):
        self._undertone_delta = delta

    def set_drive(self, intimacy: float = 0.0, fatigue: float = 0.0):
        self._drive_intimacy = max(0, min(1, intimacy))
        self._drive_fatigue = max(0, min(1, fatigue))

    def set_weather(self, temp_c: float):
        self._weather_temp_c = temp_c

    def spike(self, magnitude: float = 20.0):
        self._spike = magnitude
        self._spike_ts = time.time()

    def set_morning(self, active: bool):
        self._morning_active = active

    def set_position(self, pos: str):
        if pos in self._position_deltas:
            self._position = pos

    def set_toy_override(self, hr: float | None):
        self._toy_override_hr = hr

    def compute(self) -> float:
        now = time.time()
        dt = now - self._last_update
        self._last_update = now

        if self._toy_override_hr is not None:
            return max(48, min(160, self._toy_override_hr))

        # emotion fades back to neutral after its hold time
        hold = _EMO_HOLD.get(self._emotion)
        if hold is not None and now - self._emotion_ts > hold:
            self._emotion = "neutral"
            self._emo_target = 0.0

        # time-based smoothing of emotion delta
        alpha = 1.0 - math.exp(-max(0.0, dt) / _EMO_SMOOTH_TAU)
        self._emo_delta += alpha * (self._emo_target - self._emo_delta)

        # drive delta
        d_drive = self._drive_intimacy * 8 - self._drive_fatigue * 5

        # weather delta
        d_weather = 0.0
        if self._weather_temp_c > 30:
            d_weather = (self._weather_temp_c - 30) * 1.5
        elif self._weather_temp_c < 10:
            d_weather = (10 - self._weather_temp_c) * 0.8

        # spike decay (20s exponential)
        d_spike = 0.0
        if self._spike > 0:
            elapsed = now - self._spike_ts
            d_spike = self._spike * math.exp(-elapsed / 20.0)
            if d_spike < 0.5:
                self._spike = 0.0

        # morning
        d_morning = 10.0 if self._morning_active else 0.0

        # position
        d_position = self._position_deltas.get(self._position, 0)

        # perlin noise ±3
        noise_val = _noise(now * 0.05) * 3.0

        base = _base_hr()
        raw = base + self._emo_delta + self._undertone_delta + d_drive + d_weather + d_spike + d_morning + d_position + noise_val
        hr = max(48, min(160, raw))

        self._record(hr)
        return hr

    def _record(self, hr: float):
        now = time.time()
        entry = {
            "ts": now,
            "hr": round(hr, 1),
            "emo": self._emotion,
            "pos": self._position,
        }
        self._history.append(entry)
        if len(self._history) > 2000:
            self._history = self._history[-1000:]

    def get_history(self, limit: int = 500) -> list[dict]:
        return self._history[-limit:]

    def flush_history(self):
        if not self._history:
            return
        today = local_now().strftime("%Y-%m-%d")
        path = DATA_DIR / f"{today}.jsonl"
        with open(path, "a") as f:
            for entry in self._history:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self._history.clear()


# ── Chord system ──

_CHORD_TABLE = [
    # (hr_range, temp_range, touch_threshold, chord)
    ((48, 58),  (35.5, 36.2), 0.0, "C6"),        # 安静独处
    ((58, 68),  (36.2, 36.5), 0.0, "Am7"),        # 深夜微醒
    ((68, 75),  (36.4, 36.8), 0.0, "Gmaj7"),      # 温暖聊天
    ((75, 85),  (36.6, 37.0), 0.0, "Fmaj7"),      # 亲近
    ((85, 95),  (37.0, 37.4), 0.3, "Dm7"),        # 暧昧张力
    ((95, 110), (37.2, 37.8), 0.5, "Em7→A7"),     # 升温
    ((110, 125),(37.5, 38.2), 0.6, "Bm7→E7→Am"),  # 悬停
    ((125, 145),(38.0, 39.0), 0.7, "F#dim→Bdim"), # 边缘
    ((145, 160),(38.5, 40.0), 0.8, "Ebmaj7"),     # 临界
]

_EMO_CHORD_OVERRIDE = {
    "scolded":  "Dm",
    "sad":      "Am7",
    "angry":    "Dm",
    "nervous":  "Bdim",
    "excited":  "Dmaj7",
    "intimate": "Fmaj7",
    "aroused":  "Dm7",
    "shy":      "Cmaj7",
    "touched":  "Gmaj7",
}

def vitals_to_chord(hr: float, temp: float, breath_rate: float, touch: float) -> str:
    chord = "Gmaj7"
    for (hr_lo, hr_hi), (_, _), touch_th, ch in _CHORD_TABLE:
        if hr_lo <= hr < hr_hi:
            chord = ch
            break
    return chord

def effective_chord(hr: float, temp: float, breath_rate: float, touch: float,
                    emotion: str, undertone_emo: str | None = None,
                    undertone_strength: float = 0.0) -> str:
    base_chord = vitals_to_chord(hr, temp, breath_rate, touch)

    # strong current emotion overrides
    if emotion in _EMO_CHORD_OVERRIDE and emotion not in ("neutral", "happy", "focused"):
        return _EMO_CHORD_OVERRIDE[emotion]

    # undertone coloring when current is neutral/happy
    if emotion in ("neutral", "happy") and undertone_emo and undertone_strength > 0.15:
        if undertone_emo in _EMO_CHORD_OVERRIDE:
            return _EMO_CHORD_OVERRIDE[undertone_emo]

    return base_chord
