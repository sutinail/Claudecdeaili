"""
情绪检测 · emotion.py
T1: emoji / 叹词直接触发
T2: 语义短语 + 否定窗口
"""

import re

# ── T1: Emoji / 叹词 ──

_T1_MAP: dict[str, str] = {
    "😤": "angry",
    "😡": "angry",
    "🤬": "angry",
    "😢": "sad",
    "😭": "sad",
    "🥺": "sad",
    "😱": "startled",
    "😨": "nervous",
    "😰": "nervous",
    "😳": "shy",
    "🥰": "intimate",
    "😍": "intimate",
    "💕": "intimate",
    "❤️": "intimate",
    "💋": "intimate",
    "😏": "aroused",
    "🔥": "aroused",
    "😆": "happy",
    "😊": "happy",
    "🤗": "happy",
    "😄": "happy",
    "🥳": "excited",
    "🎉": "excited",
    "😮": "startled",
    "🤔": "focused",
    "😌": "neutral",
    "💤": "neutral",
}

_T1_EXCLAMATIONS: dict[str, str] = {
    "啊啊啊": "excited",
    "呜呜": "sad",
    "嗯嗯": "intimate",
    "嘻嘻": "happy",
    "哼": "angry",
    "唔": "nervous",
    "呀": "startled",
    "哇": "excited",
    "嗷": "startled",
    "噫": "startled",
    "嘿嘿": "happy",
    "呵呵": "neutral",
    "哈哈": "happy",
    "woo": "excited",
    "aww": "touched",
    "omg": "startled",
    "mwah": "intimate",
}

# ── T2: 语义短语 + 否定窗口 ──

_T2_PHRASES: list[tuple[str, str]] = [
    ("好开心", "happy"),
    ("好高兴", "happy"),
    ("开心", "happy"),
    ("高兴", "happy"),
    ("快乐", "happy"),
    ("好难过", "sad"),
    ("难过", "sad"),
    ("伤心", "sad"),
    ("难受", "sad"),
    ("心疼", "touched"),
    ("感动", "touched"),
    ("好感动", "touched"),
    ("紧张", "nervous"),
    ("好紧张", "nervous"),
    ("害怕", "nervous"),
    ("吓死", "startled"),
    ("吓到", "startled"),
    ("生气", "angry"),
    ("好气", "angry"),
    ("气死", "angry"),
    ("想你", "intimate"),
    ("想我", "intimate"),
    ("亲亲", "intimate"),
    ("抱抱", "intimate"),
    ("喜欢你", "intimate"),
    ("爱你", "intimate"),
    ("好害羞", "shy"),
    ("害羞", "shy"),
    ("脸红", "shy"),
    ("兴奋", "excited"),
    ("好兴奋", "excited"),
    ("期待", "excited"),
    ("专注", "focused"),
    ("认真", "focused"),
    ("无聊", "neutral"),
    ("困了", "neutral"),
    ("想睡", "neutral"),
    ("累了", "neutral"),
    ("好累", "sad"),
    ("舒服", "intimate"),
    ("好舒服", "aroused"),
    ("不行了", "aroused"),
    ("要坏掉了", "aroused"),
    ("受不了", "aroused"),
]

_NEGATIONS = {"不", "没", "别", "非", "未", "无", "莫"}
_NEG_WINDOW = 4


def detect_emotion(text: str) -> str | None:
    # T1: emoji
    for emoji, emo in _T1_MAP.items():
        if emoji in text:
            return emo

    # T1: exclamations
    text_lower = text.lower()
    for excl, emo in _T1_EXCLAMATIONS.items():
        if excl in text_lower:
            return emo

    # T2: phrases with negation window
    for phrase, emo in _T2_PHRASES:
        idx = text.find(phrase)
        if idx < 0:
            continue
        window_start = max(0, idx - _NEG_WINDOW)
        window = text[window_start:idx]
        negated = any(neg in window for neg in _NEGATIONS)
        if not negated:
            return emo

    return None
