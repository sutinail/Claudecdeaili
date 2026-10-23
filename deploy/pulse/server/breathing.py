"""
呼吸模型 · breathing.py
RATE = clamp(base + hr_sync + Δemo + Δposition + noise, 8, 35)
DEPTH = 1.0 - (rate - 8) / 27
"""

import time
import math
from .heart_rate import PerlinNoise1D

_noise = PerlinNoise1D(seed=99)

_EMO_BREATH = {
    "neutral":   0,
    "happy":     1,
    "focused":  -1,
    "sad":       0,
    "scolded":   3,
    "nervous":   4,
    "startled":  6,
    "intimate":  3,
    "aroused":   5,
    "excited":   4,
    "angry":     5,
    "shy":       2,
    "touched":   1,
}

_POSITION_BREATH = {
    "lying_back":   0,
    "lying_side":  -1,
    "lying_face":   3,
    "kneeling":     2,
    "sitting":      0,
    "standing":     1,
}

_DEPTH_LABELS = [
    (12, "很深很长"),
    (16, "深长"),
    (20, "平稳"),
    (26, "偏浅"),
    (35, "急促"),
]


class BreathingEngine:
    def __init__(self):
        self._base: float = 15.0

    def compute(self, heart_rate: float, emotion: str, position: str) -> dict:
        hr_sync = (heart_rate - 70) * 0.15

        d_emo = _EMO_BREATH.get(emotion, 0)
        d_pos = _POSITION_BREATH.get(position, 0)

        noise_val = _noise(time.time() * 0.04) * 1.5

        rate = max(8, min(35, self._base + hr_sync + d_emo + d_pos + noise_val))
        depth = round(1.0 - (rate - 8) / 27, 2)
        depth = max(0.0, min(1.0, depth))

        label = "平稳"
        for threshold, lbl in _DEPTH_LABELS:
            if rate <= threshold:
                label = lbl
                break

        return {
            "rate": round(rate, 1),
            "depth": depth,
            "label": label,
        }
