"""
体温模型 · body_temperature.py
TEMP = clamp(base + Δemo + Δweather + Δposition + Δmorning + noise, 35.5, 40.0)
"""

import time
import math
from .heart_rate import PerlinNoise1D

_noise = PerlinNoise1D(seed=77)

_EMO_TEMP_DELTAS = {
    "neutral":   0.0,
    "happy":     0.1,
    "focused":   0.0,
    "sad":      -0.2,
    "scolded":   0.3,
    "nervous":   0.2,
    "startled":  0.1,
    "intimate":  0.6,
    "aroused":   1.0,
    "excited":   0.4,
    "angry":     0.4,
    "shy":       0.3,
    "touched":   0.2,
}

_POSITION_TEMP = {
    "lying_back":  -0.1,
    "lying_side":  -0.1,
    "lying_face":   0.1,
    "kneeling":     0.2,
    "sitting":      0.0,
    "standing":     0.1,
}


class BodyTemperatureEngine:
    def __init__(self):
        self._base: float = 36.6
        self._weather_temp_c: float = 25.0
        self._toy_override: float | None = None

    def set_weather(self, temp_c: float):
        self._weather_temp_c = temp_c

    def set_toy_override(self, temp: float | None):
        self._toy_override = temp

    def compute(self, emotion: str, position: str, morning_active: bool) -> float:
        if self._toy_override is not None:
            return max(35.5, min(40.0, self._toy_override))

        d_emo = _EMO_TEMP_DELTAS.get(emotion, 0.0)

        d_weather = 0.0
        if self._weather_temp_c > 30:
            d_weather = (self._weather_temp_c - 30) * 0.05
        elif self._weather_temp_c < 10:
            d_weather = (10 - self._weather_temp_c) * -0.03

        d_position = _POSITION_TEMP.get(position, 0.0)
        d_morning = 0.3 if morning_active else 0.0

        noise_val = _noise(time.time() * 0.03) * 0.15

        raw = self._base + d_emo + d_weather + d_position + d_morning + noise_val
        return round(max(35.5, min(40.0, raw)), 1)
