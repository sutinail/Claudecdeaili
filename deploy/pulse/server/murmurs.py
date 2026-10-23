"""
碎碎念 · murmurs.py
身体状态的碎碎念不出现在聊天气泡里，有自己的独立窗口。
"""

import time
import json
from pathlib import Path
from collections import deque

DATA_PATH = Path(__file__).parent.parent / "data" / "life" / "murmurs.jsonl"
DATA_PATH.parent.mkdir(parents=True, exist_ok=True)

MAX_BUFFER = 200


class MurmurBuffer:
    def __init__(self):
        self._buffer: deque[dict] = deque(maxlen=MAX_BUFFER)
        self._load()

    def _load(self):
        if DATA_PATH.exists():
            try:
                with open(DATA_PATH, "r") as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            self._buffer.append(json.loads(line))
            except Exception:
                pass

    def add(self, text: str, source: str, **context):
        entry = {
            "ts": time.time(),
            "text": text,
            "source": source,
            **context,
        }
        self._buffer.append(entry)
        self._persist(entry)

    def _persist(self, entry: dict):
        with open(DATA_PATH, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        # trim file if too large
        if len(self._buffer) >= MAX_BUFFER:
            self._rewrite()

    def _rewrite(self):
        with open(DATA_PATH, "w") as f:
            for entry in self._buffer:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def get(self, limit: int = 50) -> list[dict]:
        items = list(self._buffer)[-limit:]
        return items

    def add_body_reaction(self, text: str, **ctx):
        self.add(text, source="body_reaction", **ctx)

    def add_narrative(self, text: str, **ctx):
        self.add(text, source="narrative", **ctx)

    def add_position(self, text: str, **ctx):
        self.add(text, source="position", **ctx)

    def add_morning(self, text: str, **ctx):
        self.add(text, source="morning", **ctx)

    def add_sensory(self, text: str, **ctx):
        self.add(text, source="sensory", **ctx)

    def add_transition(self, text: str, **ctx):
        self.add(text, source="transition", **ctx)

    def add_env(self, text: str, **ctx):
        self.add(text, source="env", **ctx)
