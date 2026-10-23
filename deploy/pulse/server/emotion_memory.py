"""
情绪底色 · emotion_memory.py
强烈情绪触发后写入底色，按指数衰减慢慢消散。
被哄机制：正面情绪进来时，负面底色衰减 ×4，同时建立浅暖底色。
"""

import time
import math

_UNDERTONE_CONFIG = {
    # emotion: (intensity, half_life_seconds)
    "scolded":   (1.0, 90 * 60),
    "sad":       (0.8, 60 * 60),
    "nervous":   (0.6, 20 * 60),
    "startled":  (0.7, 15 * 60),
    "intimate":  (0.9, 45 * 60),
    "aroused":   (0.9, 30 * 60),
    "excited":   (0.7, 20 * 60),
    "angry":     (1.0, 60 * 60),
    "touched":   (0.6, 30 * 60),
    "shy":       (0.5, 15 * 60),
}

_NEGATIVE = {"scolded", "sad", "nervous", "startled", "angry"}
_POSITIVE = {"happy", "intimate", "aroused", "excited", "touched", "shy"}
_NO_UNDERTONE = {"happy", "focused", "neutral"}

_HR_DELTAS = {
    "scolded":  12,
    "sad":      -4,
    "nervous":   8,
    "startled":  10,
    "angry":     12,
    "intimate":  10,
    "aroused":   15,
    "excited":   8,
    "touched":   5,
    "shy":       4,
}


class EmotionMemory:
    def __init__(self):
        self._layers: list[dict] = []

    def on_emotion(self, emo: str):
        if emo in _NO_UNDERTONE:
            self._try_comfort(emo)
            return

        cfg = _UNDERTONE_CONFIG.get(emo)
        if not cfg:
            return

        # if positive incoming and negative undertone exists, accelerate decay
        if emo in _POSITIVE:
            self._try_comfort(emo)

        intensity, half_life = cfg
        self._layers.append({
            "emotion": emo,
            "intensity": intensity,
            "half_life": half_life,
            "ts": time.time(),
            "comfort_mult": 1.0,
        })
        if len(self._layers) > 10:
            self._layers = self._layers[-10:]

    def _try_comfort(self, positive_emo: str):
        for layer in self._layers:
            if layer["emotion"] in _NEGATIVE:
                layer["comfort_mult"] = 4.0
        if positive_emo in _POSITIVE and positive_emo in _UNDERTONE_CONFIG:
            cfg = _UNDERTONE_CONFIG[positive_emo]
            self._layers.append({
                "emotion": positive_emo,
                "intensity": cfg[0] * 0.6,
                "half_life": cfg[1],
                "ts": time.time(),
                "comfort_mult": 1.0,
            })

    def get_effective(self) -> tuple[str | None, float]:
        """Returns (dominant_undertone_emotion, strength 0-1)."""
        now = time.time()
        best_emo = None
        best_strength = 0.0

        alive = []
        for layer in self._layers:
            elapsed = now - layer["ts"]
            decay_rate = math.log(2) / layer["half_life"] * layer["comfort_mult"]
            strength = layer["intensity"] * math.exp(-decay_rate * elapsed)
            if strength > 0.05:
                alive.append(layer)
                if strength > best_strength:
                    best_strength = strength
                    best_emo = layer["emotion"]

        self._layers = alive
        return best_emo, round(best_strength, 3)

    def hr_delta(self) -> float:
        emo, strength = self.get_effective()
        if emo and strength > 0.1:
            base_delta = _HR_DELTAS.get(emo, 0)
            return base_delta * strength * 0.4
        return 0.0
