"""语义向量 · embedding.py — 硅基流动 embeddings 接口（OpenAI 兼容）。
语料向量缓存在数据目录里，只给新句子补算；没配 key 或者连不上，调用方退回关键词匹配。"""

import json
import os
import threading
import urllib.request
from pathlib import Path

import numpy as np

API_KEY = os.getenv("SILICONFLOW_API_KEY", "")
MODEL = os.getenv("PULSE_EMBED_MODEL", "BAAI/bge-m3")
_URL = "https://api.siliconflow.cn/v1/embeddings"
_BATCH = 32


def enabled() -> bool:
    return bool(API_KEY)


def embed(texts: list[str], timeout: float = 15.0) -> np.ndarray:
    """返回 L2 归一化后的向量矩阵，行顺序和 texts 一致。"""
    rows = []
    for i in range(0, len(texts), _BATCH):
        body = json.dumps({"model": MODEL, "input": texts[i:i + _BATCH],
                           "encoding_format": "float"}).encode()
        req = urllib.request.Request(_URL, data=body, headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = sorted(json.load(resp)["data"], key=lambda d: d["index"])
        rows += [d["embedding"] for d in data]
    vecs = np.asarray(rows, dtype=np.float32)
    return vecs / np.linalg.norm(vecs, axis=1, keepdims=True)


class VectorIndex:
    """text → 向量。整体替换而不是原地改，后台补算时读的人不会看到半成品。"""

    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._rows: dict[str, int] = {}
        self._vecs = np.zeros((0, 0), dtype=np.float32)
        self._load()

    def _load(self):
        if not self._path.exists():
            return
        data = np.load(self._path, allow_pickle=False)
        if str(data["model"]) != MODEL:
            return
        texts = [str(t) for t in data["texts"]]
        self._rows = {t: i for i, t in enumerate(texts)}
        self._vecs = data["vectors"]

    def missing(self, texts: list[str]) -> list[str]:
        return [t for t in dict.fromkeys(texts) if t not in self._rows]

    def fill(self, texts: list[str]) -> int:
        """给还没有向量的句子补算并落盘，返回补了多少条。"""
        with self._lock:
            todo = self.missing(texts)
            if not todo:
                return 0
            new = embed(todo)
            old_texts = sorted(self._rows, key=self._rows.get)
            all_texts = old_texts + todo
            vecs = np.vstack([self._vecs, new]) if len(old_texts) else new
            tmp = self._path.with_suffix(".tmp.npz")
            np.savez(tmp, model=np.array(MODEL), texts=np.array(all_texts), vectors=vecs)
            tmp.replace(self._path)
            self._rows, self._vecs = {t: i for i, t in enumerate(all_texts)}, vecs
            return len(todo)

    def scores(self, query_vec: np.ndarray, texts: list[str]) -> dict[str, float]:
        rows, vecs = self._rows, self._vecs
        hits = [(t, rows[t]) for t in texts if t in rows]
        if not hits:
            return {}
        sims = vecs[[i for _, i in hits]] @ query_vec
        return {t: float(s) for (t, _), s in zip(hits, sims)}
