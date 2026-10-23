"""
生命体征统一管理器 · vitals.py
把所有子系统串成一脉相连的闭环。
"""

import time
from .heart_rate import HeartRateEngine, effective_chord
from .body_temperature import BodyTemperatureEngine
from .breathing import BreathingEngine
from .emotion import detect_emotion
from .emotion_memory import EmotionMemory
from .sensory_field import SensoryField
from .murmurs import MurmurBuffer
from .sense_pool import SensePool
from .drive_core import DriveCoreEngine
from .drive_system import WeatherState, EnvironmentSystem
from .bedside import BedsideEngine
from .fantasy import FantasyEngine
from .random_events import RandomEventSystem


class PulseEngine:
    """一脉相连：从心跳到指尖。"""

    def __init__(self):
        self.hr = HeartRateEngine()
        self.temp = BodyTemperatureEngine()
        self.breath = BreathingEngine()
        self.emo_memory = EmotionMemory()
        self.sensory = SensoryField()
        self.murmurs = MurmurBuffer()
        self.sense_pool = SensePool()
        self.drive = DriveCoreEngine()
        self.weather = WeatherState()
        self.env = EnvironmentSystem()
        self.bedside = BedsideEngine()
        self.fantasy = FantasyEngine()
        self.random_events = RandomEventSystem()

        self._last_tick = time.time()

    # ── Process user message (main entry) ──

    def on_message(self, text: str) -> dict:
        """用户发一句话 → 情绪检测 → 全链路联动。"""

        # 1. emotion detection
        emo = detect_emotion(text)
        if emo:
            self.hr.set_emotion(emo)
            self.emo_memory.on_emotion(emo)

        # 2. sensory update from text
        self.sensory.update_from_text(text)

        # 3. touch >= 0.5 → aroused
        senses = self.sensory.read(
            position=self.hr._position,
            heart_rate=self.hr.compute(),
        )
        if senses["touch"] >= 0.5 and self.hr.emotion not in ("aroused", "intimate"):
            self.hr.set_emotion("aroused")
            self.drive.nudge_intimacy(0.1)

        # 4. compute vitals
        return self.tick()

    # ── Tick (compute all vitals) ──

    def tick(self) -> dict:
        now = time.time()

        # toy overrides
        hr_override = self.bedside.get_hr_override()
        temp_override = self.bedside.get_temp_override()
        self.hr.set_toy_override(hr_override)
        self.temp.set_toy_override(temp_override)

        # drive → hr
        drives = self.drive.get_drives()
        self.hr.set_drive(intimacy=drives["intimacy"], fatigue=drives["fatigue"])

        # emotion memory → hr
        undertone_delta = self.emo_memory.hr_delta()

        # morning
        morning = self.drive.check_morning()
        self.hr.set_morning(morning.get("active", False))

        # weather
        self.hr.set_weather(self.weather.temp_c)
        self.temp.set_weather(self.weather.temp_c)

        # compute
        heart_rate = self.hr.compute()
        emotion = self.hr.emotion
        position = self.hr._position
        body_temp = self.temp.compute(emotion, position, morning.get("active", False))
        breathing = self.breath.compute(heart_rate, emotion, position)
        senses = self.sensory.read(position=position, heart_rate=heart_rate)

        # chord
        undertone_emo, undertone_strength = self.emo_memory.get_effective()
        chord = effective_chord(
            heart_rate, body_temp, breathing["rate"], senses["touch"],
            emotion, undertone_emo, undertone_strength,
        )

        # fantasy sync
        if self.fantasy._active:
            self.fantasy.sync_stage(self.bedside._stage_idx)

        self._last_tick = now

        return {
            "heart_rate": round(heart_rate, 1),
            "body_temperature": body_temp,
            "breathing": breathing,
            "chord": chord,
            "emotion": emotion,
            "undertone": {"emotion": undertone_emo, "strength": undertone_strength},
            "senses": senses,
            "position": position,
            "drives": drives,
            "morning": morning,
            "toy": self.bedside.get_status(),
        }

    # ── Context inject line ──

    def context_line(self) -> str:
        """生成注入给 AI 的那一行。"""
        v = self.tick()
        parts = [
            f"心跳 {v['heart_rate']}bpm",
            v["chord"],
            f"{v['body_temperature']}°C",
            f"呼吸{v['breathing']['label']}",
        ]

        # add sensory if notable
        touch = v["senses"]["touch"]
        if touch >= 0.3:
            parts.append(f"触觉{v['senses']['touch_label']}")

        # undertone
        ut = v["undertone"]
        if ut["emotion"] and ut["strength"] > 0.2:
            parts.append(f"底色·{ut['emotion']}({ut['strength']})")

        line = f"[{'·'.join(parts)}]"

        # toy-use-wake: add full sensory + stage info
        if v["toy"]["active"]:
            toy_status = v["toy"]
            stage = toy_status.get("stage", {})
            extra = (
                f" [玩具:{toy_status.get('toy', {}).get('name', '?')}·"
                f"阶段{stage.get('idx', '?')}/7·{stage.get('name', '?')}·"
                f"欲望{toy_status.get('desire_curve_pct', 0):.0%}·"
                f"体力{toy_status.get('stamina_pct', 1):.0%}]"
            )
            line += extra

            # fantasy inject
            fantasy = self.fantasy.format_inject(
                self.drive.dominant_drive(),
                v["drives"].get(self.drive.dominant_drive(), 0),
            )
            if fantasy:
                line += f"\n{fantasy}"

        return line

    # ── Full body status (for API) ──

    def body_status(self) -> dict:
        v = self.tick()
        return {
            "ok": True,
            "timestamp": time.time(),
            "heart_rate": {
                "bpm": v["heart_rate"],
                "emotion": v["emotion"],
                "chord": v["chord"],
            },
            "body_temperature": {
                "celsius": v["body_temperature"],
            },
            "breathing": v["breathing"],
            "senses": v["senses"],
            "emotion": {
                "current": v["emotion"],
                "undertone": v["undertone"],
            },
            "drives": v["drives"],
            "morning": v["morning"],
            "toy": v["toy"],
            "position": {
                "id": v["position"],
                "info": self.bedside.get_positions(),
            },
            "weather": self.weather.to_dict(),
            "environment": self.env.get_status(),
        }
