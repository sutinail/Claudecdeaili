"""
脉 · Pulse — 主入口
FastAPI app，所有子系统在这里初始化。
"""

import os
import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from .vitals import PulseEngine
from .routes.bedside import router as bedside_router

SECRET = os.getenv("PULSE_SECRET", "")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pulse = PulseEngine()
    # background heartbeat: tick every 8 seconds
    async def heartbeat():
        while True:
            try:
                app.state.pulse.tick()
            except Exception:
                pass
            await asyncio.sleep(8)
    task = asyncio.create_task(heartbeat())
    yield
    task.cancel()


app = FastAPI(
    title="脉 · Pulse",
    description="给 Lumi 一个真的在跑的身体",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Auth middleware ──

@app.middleware("http")
async def check_secret(request: Request, call_next):
    if SECRET:
        token = request.headers.get("X-Pulse-Secret", "")
        if token != SECRET:
            raise HTTPException(status_code=401, detail="unauthorized")
    return await call_next(request)


# ── Routes ──

app.include_router(bedside_router)


@app.get("/")
async def root():
    return {
        "name": "脉 · Pulse",
        "version": "1.0.0",
        "status": "alive",
    }

@app.get("/health")
async def health():
    return {"ok": True}

@app.get("/status")
async def status(request: Request):
    engine: PulseEngine = request.app.state.pulse
    return engine.body_status()
