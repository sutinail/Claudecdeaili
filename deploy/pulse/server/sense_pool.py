"""
语料池匹配器 · sense_pool.py
身体事件语料，按当前状态匹配抽取；支持运行时增删查。
"""

import json
import random
from pathlib import Path
from collections import Counter, deque

from . import embedding

DATA_PATH = Path(__file__).parent.parent / "data" / "sense_pool.json"
VECTORS_PATH = DATA_PATH.parent / "sense_vectors.npz"

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


# 场景类语料写的是"正在发生的事"，只有指定了这个场景才抽
SCENES = {
    "daddy_play", "bath_play", "mirror_play", "oral_play",
    "tender_sex", "foreplay_tease", "kiss_play", "location_play",
}


class SensePool:
    def __init__(self):
        self._pool: list[dict] = []
        self._recent: deque[str] = deque(maxlen=20)
        self._load()
        self.vectors = embedding.VectorIndex(VECTORS_PATH) if embedding.enabled() else None
        self._embed_error_logged = False

    def fill_vectors(self) -> int:
        """给还没有向量的语料补算（启动时和定时任务里调）。"""
        if not self.vectors:
            return 0
        return self.vectors.fill([item.get("text", "") for item in self._pool])

    def _query_scores(self, query: str | None, texts: list[str]) -> dict[str, float]:
        if not (query and self.vectors and texts):
            return {}
        try:
            q = embedding.embed([query], timeout=5.0)[0]
        except Exception as err:
            if not self._embed_error_logged:
                print(f"🧭 语义匹配失败，退回关键词：{err}")
                self._embed_error_logged = True
            return {}
        self._embed_error_logged = False
        return self.vectors.scores(q, texts)

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
              stage_idx: int, context: str = "advance",
              scene: str | None = None) -> str | None:
        categories = self._context_categories(context)
        if context == "advance":
            categories = (categories - SCENES) | ({scene} & SCENES)
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

    def pick_many(self, intensity: float, body_parts: set[str] | None = None,
                  scene: str | None = None, k: int = 3, query: str | None = None) -> list[str]:
        """聊天 / 触碰时抽 k 句身体反应候选。
        只用 general，加上明确在进行的那个 scene：场景类语料写的是"正在发生的事"，乱冒会穿帮。
        从最贴的条件往下放宽：场景+部位 → 场景 → 部位 → 只看强度。
        有 query 且配了向量时，每一层里按语义相近排序（前几名里再随机，避免老是同一句）；否则随机。"""
        scene = scene if scene in SCENES else None
        tiers = []
        if scene:
            tiers += [({scene}, body_parts), ({scene}, None)]
        if body_parts:
            tiers.append(({"general"}, body_parts))
        tiers.append(({"general"}, None))

        tier_pools = [self._candidates(intensity, cats, parts) for cats, parts in tiers]
        scores = self._query_scores(query, list({t for pool in tier_pools for t in pool}))

        def score(t: str) -> float:
            return scores.get(t, -1.0)

        chosen: list[str] = []
        for pool in tier_pools:
            pool = [t for t in pool if t not in chosen]
            need = k - len(chosen)
            if scores:
                top = sorted(pool, key=score, reverse=True)[:max(2 * k, 6)]
                pool = sorted(random.sample(top, min(need, len(top))), key=score, reverse=True)
            else:
                random.shuffle(pool)
            chosen += pool[:need]
            if len(chosen) >= k:
                break

        self._recent.extend(chosen)
        return chosen

    def _candidates(self, intensity: float, categories: set[str],
                    body_parts: set[str] | None) -> list[str]:
        out = []
        for item in self._pool:
            if item.get("category") not in categories:
                continue
            if item.get("toys") is not None or item.get("positions") is not None:
                continue
            if body_parts is not None and item.get("body_part") not in body_parts:
                continue
            lo, hi = item.get("intensity", [0, 1])
            if not (lo - 0.15 <= intensity <= hi + 0.15):
                continue
            text = item.get("text", "")
            if text not in self._recent:
                out.append(text)
        return out

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
        if category not in _CATEGORY_WEIGHTS:
            raise ValueError(f"未知分类 {category}，可用: {', '.join(_CATEGORY_WEIGHTS)}")
        if any(item.get("text") == text for item in self._pool):
            raise ValueError("这句已经在语料池里了")
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
        existing = {item.get("text") for item in self._pool}
        for e in entries:
            if "text" not in e or e.get("category") not in _CATEGORY_WEIGHTS:
                continue
            if e["text"] in existing:
                continue
            existing.add(e["text"])
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
