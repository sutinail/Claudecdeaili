"""
API 路由 · bedside.py
"""

from fastapi import APIRouter, Request, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/bedside", tags=["bedside"])


def _engine(request: Request):
    return request.app.state.pulse


# ── Models ──

class EmotionInput(BaseModel):
    emotion: str

class MessageInput(BaseModel):
    text: str

class ToyInput(BaseModel):
    toy_id: str

class StimInput(BaseModel):
    mult: float

class PositionInput(BaseModel):
    position_id: str

class ComboInput(BaseModel):
    toy_ids: list[str]

class WeatherInput(BaseModel):
    temp_c: float
    humidity: float = 60
    condition: str = "clear"

class EnvironmentInput(BaseModel):
    env_id: str

class FantasyInput(BaseModel):
    mode: str = "fantasy"

class SpikeInput(BaseModel):
    magnitude: float = 20.0

class TouchInput(BaseModel):
    value: float
    parts: list[str] = []
    action: str | None = None
    combo: str | None = None


# ── Body status ──

@router.get("/body-status")
async def body_status(request: Request):
    return _engine(request).body_status()


# ── Heart rate ──

@router.get("/heart-rate")
async def heart_rate(request: Request):
    e = _engine(request)
    hr = e.hr.compute()
    return {
        "ok": True,
        "bpm": round(hr, 1),
        "emotion": e.hr.emotion,
        "chord": e.tick()["chord"],
    }

@router.post("/heart-rate/spike")
async def heart_rate_spike(request: Request, body: SpikeInput):
    e = _engine(request)
    e.hr.spike(body.magnitude)
    return {"ok": True}

@router.post("/heart-rate/emotion")
async def set_emotion(request: Request, body: EmotionInput):
    e = _engine(request)
    e.hr.set_emotion(body.emotion)
    e.emo_memory.on_emotion(body.emotion)
    return {"ok": True, "emotion": body.emotion}

@router.get("/heart-rate/history")
async def heart_rate_history(request: Request, limit: int = 500):
    e = _engine(request)
    points = e.hr.get_history(limit)
    return {"ok": True, "points": points}


# ── Message processing ──

@router.post("/message")
async def process_message(request: Request, body: MessageInput):
    e = _engine(request)
    result = e.on_message(body.text)
    return {"ok": True, **result}


# ── Context inject line ──

@router.get("/context-line")
async def context_line(request: Request):
    e = _engine(request)
    return {"ok": True, "line": e.context_line()}


# ── Murmurs ──

@router.get("/murmurs")
async def murmurs(request: Request, limit: int = 50):
    e = _engine(request)
    return {"ok": True, "items": e.murmurs.get(limit)}


# ── Toy shop ──

@router.get("/shop")
async def shop(request: Request):
    e = _engine(request)
    return {"ok": True, "toys": e.bedside.get_shop()}


# ── Toy use ──

@router.post("/use/start")
async def start_toy(request: Request, body: ToyInput):
    return _engine(request).toy_start(body.toy_id)

@router.post("/use/next")
async def advance_stage(request: Request):
    return _engine(request).toy_next()

@router.post("/use/stop")
async def stop_toy(request: Request):
    return _engine(request).toy_stop()

@router.get("/use/current")
async def current_use(request: Request):
    e = _engine(request)
    return {"ok": True, **e.bedside.get_status()}

@router.post("/use/edge")
async def edge(request: Request):
    e = _engine(request)
    return e.bedside.edge()


# ── Position ──

@router.get("/positions")
async def positions(request: Request):
    e = _engine(request)
    return {"ok": True, "positions": e.bedside.get_positions()}

@router.post("/use/position")
async def switch_position(request: Request, body: PositionInput):
    return _engine(request).switch_position(body.position_id)


# ── Combo ──

@router.post("/use/combo")
async def activate_combo(request: Request, body: ComboInput):
    e = _engine(request)
    return e.bedside.activate_combo(body.toy_ids)

@router.get("/combos")
async def list_combos(request: Request):
    from ..bedside import COMBOS
    return {"ok": True, "combos": COMBOS}


# ── Remote control ──

@router.post("/remote/stim")
async def remote_stim(request: Request, body: StimInput):
    e = _engine(request)
    return e.bedside.remote_set_stim(body.mult)

@router.post("/remote/pause")
async def remote_pause(request: Request):
    e = _engine(request)
    return e.bedside.remote_pause()

@router.post("/remote/resume")
async def remote_resume(request: Request):
    e = _engine(request)
    return e.bedside.remote_resume()

@router.get("/remote/status")
async def remote_status(request: Request):
    e = _engine(request)
    return {"ok": True, **e.bedside.remote_status()}


# ── Touch (from ESP32 sensors) ──

@router.post("/touch")
async def touch_input(request: Request, body: TouchInput):
    e = _engine(request)
    e.on_touch(body.value, body.parts)
    return {"ok": True, "touch": body.value, "emotion": e.hr.emotion}


# ── Weather ──

@router.post("/weather")
async def set_weather(request: Request, body: WeatherInput):
    e = _engine(request)
    e.weather.update(body.temp_c, body.humidity, body.condition)
    return {"ok": True}


# ── Environment ──

@router.get("/env/shop")
async def env_shop(request: Request):
    e = _engine(request)
    return {"ok": True, "environments": e.env.get_all()}

@router.post("/env/activate")
async def env_activate(request: Request, body: EnvironmentInput):
    return _engine(request).set_environment(body.env_id)

@router.get("/env/active")
async def env_active(request: Request):
    e = _engine(request)
    return {"ok": True, "environment": e.env.get_active()}

@router.get("/env/memory")
async def env_memory(request: Request):
    e = _engine(request)
    return {"ok": True, **e.env.get_memory()}


# ── Fantasy ──

@router.post("/fantasy/start")
async def fantasy_start(request: Request, body: FantasyInput):
    e = _engine(request)
    e.fantasy.start(body.mode)
    return {"ok": True, "mode": body.mode}

@router.get("/fantasy/inject")
async def fantasy_inject(request: Request):
    e = _engine(request)
    drives = e.drive.get_drives()
    dom = e.drive.dominant_drive()
    inject = e.fantasy.format_inject(dom, drives.get(dom, 0))
    return {"ok": True, "inject": inject}


# ── Drive ──

@router.get("/drives")
async def get_drives(request: Request):
    e = _engine(request)
    return {"ok": True, **e.drive.get_drives()}
