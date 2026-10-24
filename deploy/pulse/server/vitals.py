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

TOUCH_PARTS = {"top", "cheek", "chest", "back", "belly", "hand_l", "hand_r", "lap", "foot"}
_INTIMATE_PARTS = {"chest", "belly", "lap"}
_TOUCH_EMO_RANK = {"touched": 1, "intimate": 2, "aroused": 3}

# touch 部位 → 语料池里的 body_part 名字
_PART_CORPUS = {
    "top":    ["头", "头皮", "后脑勺", "额头", "鬓角"],
    "cheek":  ["脸", "下巴", "嘴唇", "耳朵", "太阳穴"],
    "chest":  ["胸口", "胸", "乳头", "心脏", "呼吸"],
    "back":   ["背部", "背", "脊椎", "肩胛骨", "后腰", "肩膀"],
    "belly":  ["小腹", "腹肌", "肚子", "腰"],
    "hand_l": ["手", "手指", "手心", "手臂"],
    "hand_r": ["手", "手指", "手心", "手臂"],
    "lap":    ["大腿", "大腿内侧", "性器", "骨盆", "胯", "臀部"],
    "foot":   ["脚", "脚趾", "小腿", "膝盖"],
}

# 聊天时这些情绪出现，才从语料池里抽一句身体反应
_REACTIVE_EMOTIONS = {"touched", "intimate", "aroused", "shy", "excited", "startled", "nervous"}


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
        self._reaction: str | None = None

    def _pick_reaction(self, intensity: float, parts: list[str] | None = None):
        body_parts = None
        if parts:
            body_parts = {bp for p in parts for bp in _PART_CORPUS.get(p, [])}
        self._reaction = self.sense_pool.pick(intensity, body_parts)

    # ── Process user message (main entry) ──

    def on_message(self, text: str) -> dict:
        """用户发一句话 → 情绪检测 → 全链路联动。"""

        # 1. emotion detection
        emo = detect_emotion(text)
        if emo:
            self.hr.set_emotion(emo)
            self.emo_memory.on_emotion(emo)

        # 2. sensory update from text
        text_touch = self.sensory.update_from_text(text)

        # 3. 只看这句话本身带来的触觉：残留的触觉不该把随便一句话变成 aroused
        senses = self.sensory.read(
            position=self.bedside.position,
            heart_rate=self.hr.compute(),
        )
        if text_touch >= 0.4 and self.hr.emotion != "aroused":
            self.hr.set_emotion("aroused")
            self.emo_memory.on_emotion("aroused")
            self.drive.nudge_intimacy(0.1)
        elif text_touch >= 0.2 and not emo:
            self.hr.set_emotion("touched")
            self.emo_memory.on_emotion("touched")

        # 4. compute vitals
        v = self.tick()

        # 5. body reaction from corpus when something actually stirred
        if emo in _REACTIVE_EMOTIONS or text_touch >= 0.2:
            intensity = max(senses["touch"], (v["heart_rate"] - 65) / 80)
            self._pick_reaction(max(0.0, min(1.0, intensity)))
        return v

    # ── Touch (MCP tool / ESP32 bear) ──

    def on_touch(self, value: float, parts: list[str] | None = None) -> dict:
        """触碰 → 触觉 + 心跳尖峰 + 情绪 + 亲密驱动。value 已经是最终力度，这里不再按部位加权。"""
        value = max(0.0, min(1.0, value))
        parts = [p for p in (parts or []) if p in TOUCH_PARTS]
        intimate = any(p in _INTIMATE_PARTS for p in parts)

        self.sensory.set_touch(value)
        self.hr.spike(value * (26 if intimate else 20))
        self.drive.nudge_intimacy(value * (0.15 if intimate else 0.05))

        if value >= 0.7 and intimate:
            emo = "aroused"
        elif value >= 0.5:
            emo = "intimate"
        elif value >= 0.2:
            emo = "touched"
        else:
            emo = None

        # 只往上升级，轻碰不会把已经很热的状态拉回 touched
        current_rank = _TOUCH_EMO_RANK.get(self.hr.emotion, 0)
        if emo and _TOUCH_EMO_RANK[emo] >= current_rank:
            self.hr.set_emotion(emo)
            self.emo_memory.on_emotion(emo)

        if value >= 0.2:
            self._pick_reaction(value, parts)
        return self.tick()

    # ── Bedside actions (shared by HTTP routes and MCP tools) ──

    def switch_position(self, pos_id: str) -> dict:
        result = self.bedside.switch_position(pos_id)
        if result["ok"]:
            self.murmurs.add_position(f"换到{result['position']['name']}", position=pos_id)
        return result

    def set_environment(self, env_id: str) -> dict:
        if env_id == "none":
            self.env.deactivate()
            return {"ok": True, "environment": None}
        env = self.env.activate(env_id)
        if not env:
            return {"ok": False, "error": "unknown_environment"}
        self.murmurs.add_env(f"换到{env['name']}", env_id=env_id)
        return {"ok": True, "environment": env}

    def toy_start(self, toy_id: str) -> dict:
        if self.drive.is_refractory():
            return {"ok": False, "error": "refractory",
                    "refractory_minutes": round(self.drive.refractory_remaining_min(), 1)}
        result = self.bedside.start_toy(toy_id)
        if result["ok"]:
            self.fantasy.start()
        return result

    def toy_next(self) -> dict:
        result = self.bedside.advance_stage()
        if not result["ok"]:
            return result

        event = self.random_events.roll()
        if event:
            result["random_event"] = event
            self.murmurs.add(event["text"], source="random_event",
                             mood=event.get("mood", "neutral"))

        stage = result.get("stage", {})
        toy_id = self.bedside._active_toy
        reaction = self.sense_pool.match(toy_id, self.bedside.position, stage.get("idx", 0))
        if reaction:
            result["body_reaction"] = reaction
            self._reaction = reaction
            self.murmurs.add_body_reaction(reaction, stage=stage.get("idx"), toy_id=toy_id)

        self.fantasy.sync_stage(stage.get("idx", 0))

        if stage.get("idx") == 7:
            self.drive.record_intimacy()
            self.drive.start_refractory()
            self.bedside.stop()
            self.fantasy.stop()
        return result

    def toy_stop(self) -> dict:
        result = self.bedside.stop()
        if result["ok"]:
            self.fantasy.stop()
        return result

    # ── Tick (compute all vitals) ──

    def tick(self) -> dict:
        now = time.time()

        # toy overrides
        hr_override = self.bedside.get_hr_override()
        temp_override = self.bedside.get_temp_override()
        self.hr.set_toy_override(hr_override)
        self.temp.set_toy_override(temp_override)

        # drive → hr
        self.drive.decay(now - self._last_tick)
        drives = self.drive.get_drives()
        self.hr.set_drive(intimacy=drives["intimacy"], fatigue=drives["fatigue"])

        # emotion memory → hr
        self.hr.set_undertone(self.emo_memory.hr_delta())

        # morning
        morning = self.drive.check_morning()
        self.hr.set_morning(morning.get("active", False))

        # weather
        self.hr.set_weather(self.weather.temp_c, self.weather.condition)
        self.temp.set_weather(self.weather.temp_c)

        # position: bedside is the single source of truth
        position = self.bedside.position
        self.hr.set_position(position)

        # compute
        heart_rate = self.hr.compute()
        emotion = self.hr.emotion
        body_temp = self.temp.compute(emotion, position, morning.get("active", False))
        breathing = self.breath.compute(heart_rate, emotion, position)
        senses = self.sensory.read(position=position, heart_rate=heart_rate)

        # environment (烛光 / 雨声 / 全黑…) amplifies or dulls the senses
        for ch in ("touch", "smell", "taste", "sound"):
            senses[ch] = round(min(1.0, senses[ch] * self.env.get_modifier(ch)), 3)
        senses["touch_label"] = self.sensory.touch_label(senses["touch"])

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

        env = self.env.get_active()
        if env:
            parts.append(env["name"])

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

        # one-shot body reaction picked by the last sense/touch/toy step
        if self._reaction:
            line += f"\n「身体」{self._reaction}"
            self._reaction = None

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
