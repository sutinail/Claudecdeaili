"""
语料池匹配器 · sense_pool.py
1120 条身体事件，按当前状态匹配抽取。
"""

import json
import random
from pathlib import Path
from collections import deque

DATA_PATH = Path(__file__).parent.parent / "data" / "sense_pool.json"

_CATEGORY_WEIGHTS = {
    "general": 1.0,
    "toy_specific": 2.0,
    "position": 1.0,
    "transition": 1.0,
    "extreme": 2.5,
    "afterglow": 1.0,
}


class SensePool:
    def __init__(self):
        self._pool: list[dict] = []
        self._recent: deque[str] = deque(maxlen=20)
        self._load()

    def _load(self):
        if DATA_PATH.exists():
            try:
                with open(DATA_PATH, "r") as f:
                    self._pool = json.load(f)
            except Exception:
                self._pool = []

    def match(self, toy_id: str | None, position_id: str | None,
              stage_idx: int, context: str = "advance") -> str | None:
        """
        context: "advance" | "afterglow" | "transition"
        """
        categories = self._context_categories(context)
        intensity = stage_idx / 7.0  # 0-1 normalized

        candidates = []
        for item in self._pool:
            cat = item.get("category", "general")
            if cat not in categories:
                continue

            # toy filter
            item_toys = item.get("toys")
            if item_toys is not None and toy_id not in item_toys:
                continue

            # position filter
            item_pos = item.get("positions")
            if item_pos is not None and position_id not in item_pos:
                continue

            # intensity filter (skip for transition/afterglow)
            if context == "advance":
                lo, hi = item.get("intensity", [0, 1])
                if not (lo <= intensity <= hi):
                    continue

            text = item.get("text", "")
            if text in self._recent:
                continue

            weight = _CATEGORY_WEIGHTS.get(cat, 1.0)
            if cat == "extreme" and intensity > 0.7:
                weight *= 2.5

            candidates.append((text, weight))

        if not candidates:
            return None

        texts, weights = zip(*candidates)
        chosen = random.choices(texts, weights=weights, k=1)[0]
        self._recent.append(chosen)
        return chosen

    def _context_categories(self, ctx: str) -> set[str]:
        if ctx == "afterglow":
            return {"afterglow"}
        elif ctx == "transition":
            return {"transition"}
        else:
            return {"general", "toy_specific", "position", "extreme"}

    @property
    def loaded(self) -> bool:
        return len(self._pool) > 0

    @property
    def count(self) -> int:
        return len(self._pool)
