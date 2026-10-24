"""真实天气 · weather_fetch.py — Open-Meteo，免费、不要 key。坐标来自 PULSE_WEATHER_LAT / PULSE_WEATHER_LON。"""

import json
import os
import urllib.request

LAT = os.getenv("PULSE_WEATHER_LAT", "")
LON = os.getenv("PULSE_WEATHER_LON", "")

_URL = (
    "https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}"
    "&current=temperature_2m,relative_humidity_2m,weather_code"
)


def _condition(code: int) -> str:
    # WMO weather codes
    if code == 0:
        return "clear"
    if code <= 3:
        return "cloudy"
    if code in (45, 48):
        return "fog"
    if code in (71, 73, 75, 77, 85, 86):
        return "snow"
    if code >= 95:
        return "storm"
    return "rain"


def fetch() -> tuple[float, float, str] | None:
    """返回 (气温°C, 湿度%, 天气)；没配置坐标返回 None。网络错误直接抛出，由调用方决定怎么处理。"""
    if not (LAT and LON):
        return None
    with urllib.request.urlopen(_URL.format(lat=LAT, lon=LON), timeout=10) as resp:
        current = json.load(resp)["current"]
    return (
        float(current["temperature_2m"]),
        float(current["relative_humidity_2m"]),
        _condition(int(current["weather_code"])),
    )
