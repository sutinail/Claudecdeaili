"""
语料池匹配器 · sense_pool.py
身体事件语料，按当前状态匹配抽取；支持运行时增删查。
"""

import json
import random
from pathlib import Path
from collections import Counter, deque

DATA_PATH = Path(__file__).parent.parent / "data" / "sense_pool.json"

_CATEGORY_WEIGHTS = {
    "general": 1.0,
    "toy_specific": 2.0,
    "position": 1.0,
    "transition": 1.0,
    "extreme": 2.5,
    "afterglow": 1.0,
    "daddy_play": 2.0,
    "bath_play": 1.5,
    "mirror_play": 1.5,
    "oral_play": 1.5,
    "tender_sex": 1.0,
    "foreplay_tease": 1.5,
    "kiss_play": 1.0,
    "location_play": 1.5,
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

    def _save(self):
        DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(DATA_PATH, "w") as f:
            json.dump(self._pool, f, ensure_ascii=False, indent=2)

    def match(self, toy_id: str | None, position_id: str | None,
              stage_idx: int, context: str = "advance") -> str | None:
        categories = self._context_categories(context)
        intensity = stage_idx / 7.0

        candidates = []
        for item in self._pool:
            cat = item.get("category", "general")
            if cat not in categories:
                continue
            item_toys = item.get("toys")
            if item_toys is not None and toy_id not in item_toys:
                continue
            item_pos = item.get("positions")
            if item_pos is not None and position_id not in item_pos:
                continue
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
            return set(_CATEGORY_WEIGHTS.keys()) - {"afterglow", "transition"}

    # ── 语料管理 ──

    def add(self, text: str, category: str, body_part: str,
            sensation: str, intensity_min: float = 0.3,
            intensity_max: float = 0.7,
            toys: list[str] | None = None,
            positions: list[str] | None = None) -> dict:
        entry = {
            "text": text,
            "category": category,
            "body_part": body_part,
            "sensation": sensation,
            "intensity": [intensity_min, intensity_max],
            "toys": toys,
            "positions": positions,
        }
        self._pool.append(entry)
        self._save()
        return entry

    def add_batch(self, entries: list[dict]) -> int:
        added = 0
        for e in entries:
            if "text" not in e or "category" not in e:
                continue
            self._pool.append({
                "text": e["text"],
                "category": e.get("category", "general"),
                "body_part": e.get("body_part", "全身"),
                "sensation": e.get("sensation", "unspecified"),
                "intensity": e.get("intensity", [0.3, 0.7]),
                "toys": e.get("toys"),
                "positions": e.get("positions"),
            })
            added += 1
        if added:
            self._save()
        return added

    def search(self, query: str, limit: int = 10) -> list[dict]:
        results = []
        q = query.lower()
        for item in self._pool:
            text = item.get("text", "").lower()
            cat = item.get("category", "").lower()
            part = item.get("body_part", "").lower()
            sens = item.get("sensation", "").lower()
            if q in text or q in cat or q in part or q in sens:
                results.append(item)
                if len(results) >= limit:
                    break
        return results

    def stats(self) -> dict:
        cats = Counter(item.get("category", "?") for item in self._pool)
        parts = Counter(item.get("body_part", "?") for item in self._pool)
        return {
            "total": len(self._pool),
            "categories": dict(cats.most_common()),
            "top_body_parts": dict(parts.most_common(15)),
            "category_count": len(cats),
            "body_part_count": len(parts),
        }

    def categories(self) -> dict[str, int]:
        return dict(Counter(
            item.get("category", "?") for item in self._pool
        ).most_common())

    @property
    def loaded(self) -> bool:
        return len(self._pool) > 0

    @property
    def count(self) -> int:
        return len(self._pool)
