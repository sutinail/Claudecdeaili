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
from .sense_pool import SCENES

_ENV_SCENE = {"bath": "bath_play", "outdoor": "location_play"}

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

# 聊天时这些情绪出现，才从语料池里抽身体反应
_REACTIVE_EMOTIONS = {"touched", "intimate", "aroused", "shy", "excited", "startled", "nervous",
                      "sad", "angry", "scolded"}

# 话里提到的部位 → 语料池 body_part（长词先匹配）
_PART_KEYWORDS = {
    "嘴唇": ["嘴唇", "嘴"], "嘴": ["嘴唇", "嘴", "嘴巴"], "舌": ["嘴", "嘴唇", "喉咙"],
    "耳": ["耳朵"], "脖子": ["脖子"], "锁骨": ["脖子", "胸口"], "喉": ["喉咙"],
    "脸": ["脸", "下巴"], "眼": ["眼睛"], "额头": ["额头"], "头发": ["头", "头皮"],
    "胸": ["胸口", "胸", "乳头"], "奶": ["胸", "乳头"], "心口": ["心脏", "胸口"], "心跳": ["心脏"],
    "腰": ["腰", "后腰"], "背": ["背部", "背", "脊椎"], "肩": ["肩膀"],
    "肚子": ["小腹", "肚子", "腹肌"], "小腹": ["小腹"], "腹肌": ["腹肌"],
    "手": ["手", "手指", "手心", "手臂"], "指": ["手指"],
    "大腿": ["大腿", "大腿内侧"], "腿": ["大腿", "腿", "小腿", "膝盖"],
    "屁股": ["臀部"], "臀": ["臀部"], "脚": ["脚", "脚趾"],
}

# 话里出现这些词，就认为是在这个场景里
_SCENE_KEYWORDS = {
    "bath_play":      ["浴室", "洗澡", "泡澡", "浴缸", "淋浴", "花洒"],
    "mirror_play":    ["镜子", "镜前", "照镜"],
    "daddy_play":     ["daddy", "爹地"],
    "oral_play":      ["口交", "含住", "含着", "深喉"],
    "kiss_play":      ["接吻", "亲嘴", "舌吻", "吻你", "吻我"],
    "foreplay_tease": ["前戏", "挑逗", "解扣子", "脱衣服", "扯领带"],
    "tender_sex":     ["慢慢做", "温柔地做", "温柔一点做"],
    "location_play":  ["车里", "野外", "阳台", "办公室", "楼梯间"],
}


def _parts_from_hint(hint: str) -> set[str]:
    """part 参数可以是 touch 部位 id、语料里的部位名，或者一句话里的部位词。"""
    if hint in _PART_CORPUS:
        return set(_PART_CORPUS[hint])
    found = _parts_in_text(hint)
    return found or {hint}


_PART_STOPWORDS = ["手机", "耳机", "眼泪", "背景", "背书", "指望", "指导", "腰包", "奶茶", "牛奶", "脸书"]


def _parts_in_text(text: str) -> set[str]:
    found: set[str] = set()
    remaining = text
    for word in _PART_STOPWORDS:
        remaining = remaining.replace(word, "\0")
    for word in sorted(_PART_KEYWORDS, key=len, reverse=True):
        if word in remaining:
            found.update(_PART_KEYWORDS[word])
            remaining = remaining.replace(word, "\0")
    return found


def _scene_in_text(text: str) -> str | None:
    lowered = text.lower()
    for scene, words in _SCENE_KEYWORDS.items():
        if any(w in lowered for w in words):
            return scene
    return None


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
        self._reactions: list[str] = []
        self._scene: str | None = None

    @property
    def scene(self) -> str | None:
        if self._scene:
            return self._scene
        env = self.env.get_active()
        return _ENV_SCENE.get(env["id"]) if env else None

    def _pick_reactions(self, intensity: float, body_parts: set[str] | None = None,
                        scene: str | None = None, query: str = ""):
        scene = scene or self.scene
        if scene:
            query = f"{query} {' '.join(_SCENE_KEYWORDS[scene][:2])}"
        self._reactions = self.sense_pool.pick_many(
            max(0.0, min(1.0, intensity)), body_parts or None, scene, query=query.strip(),
        )

    # ── Process user message (main entry) ──

    def on_message(self, text: str, scene: str = "", part: str = "") -> dict:
        """用户发一句话 → 情绪检测 → 全链路联动。
        scene / part 是调用方（我）根据整段对话给的提示；不给就从这句话里自己认。"""

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

        # 5. body reaction candidates when something actually stirred
        scene = scene if scene in SCENES else _scene_in_text(text)
        body_parts = _parts_from_hint(part) if part else _parts_in_text(text)
        if emo in _REACTIVE_EMOTIONS or text_touch >= 0.2 or scene or part:
            intensity = max(senses["touch"], (v["heart_rate"] - 65) / 80)
            self._pick_reactions(intensity, body_parts, scene, query=f"{text} {part}")
        return v

    # ── Touch (MCP tool / ESP32 bear) ──

    def on_touch(self, value: float, parts: list[str] | None = None, scene: str = "") -> dict:
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
            body_parts = {bp for p in parts for bp in _PART_CORPUS[p]}
            force = "轻轻碰了一下" if value < 0.4 else "摸着" if value < 0.7 else "用力按住"
            query = f"{'、'.join(_PART_CORPUS[parts[0]][:2]) if parts else '身上'}被她{force}"
            self._pick_reactions(value, body_parts, scene if scene in SCENES else None, query=query)
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

    def toy_start(self, toy_id: str, scene: str | None = None) -> dict:
        if scene and scene not in SCENES:
            return {"ok": False, "error": "unknown_scene"}
        if self.drive.is_refractory():
            return {"ok": False, "error": "refractory",
                    "refractory_minutes": round(self.drive.refractory_remaining_min(), 1)}
        result = self.bedside.start_toy(toy_id)
        if result["ok"]:
            self._scene = scene or None
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
        reaction = self.sense_pool.match(toy_id, self.bedside.position, stage.get("idx", 0),
                                         scene=self.scene)
        if reaction:
            result["body_reaction"] = reaction
            self._reactions = [reaction]
            self.murmurs.add_body_reaction(reaction, stage=stage.get("idx"), toy_id=toy_id)

        self.fantasy.sync_stage(stage.get("idx", 0))

        if stage.get("idx") == 7:
            self.drive.record_intimacy()
            self.drive.start_refractory()
            self.bedside.stop()
            self.fantasy.stop()
            self._scene = None
        return result

    def toy_stop(self) -> dict:
        result = self.bedside.stop()
        if result["ok"]:
            self.fantasy.stop()
            self._scene = None
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
                f"体力{toy_status.get('stamina_pct', 1):.0%}"
                f"{'·场景' + self.scene if self.scene else ''}]"
            )
            line += extra

            # fantasy inject
            fantasy = self.fantasy.format_inject(
                self.drive.dominant_drive(),
                v["drives"].get(self.drive.dominant_drive(), 0),
            )
            if fantasy:
                line += f"\n{fantasy}"

        # one-shot body reactions picked by the last sense/touch/toy step
        if len(self._reactions) == 1:
            line += f"\n「身体」{self._reactions[0]}"
        elif self._reactions:
            line += "\n「身体·候选」挑最贴的一句用，或顺着改写：\n"
            line += "\n".join(f"- {r}" for r in self._reactions)
        self._reactions = []

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
