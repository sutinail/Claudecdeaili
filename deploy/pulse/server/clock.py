"""本地时间 · clock.py — 容器默认跑 UTC，身体节律要按 Timiya 的时区走。"""

import os
from datetime import datetime, timedelta, timezone

_TZ = timezone(timedelta(hours=float(os.getenv("PULSE_TZ_OFFSET", "8"))))


def local_now() -> datetime:
    return datetime.now(_TZ)
