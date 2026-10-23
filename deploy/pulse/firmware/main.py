"""
ESP32-S3 MicroPython 固件 · main.py
读取 FSR406 传感器 → 识别动作 → POST 到 Pulse 服务器

接线：
  FSR406 一端 → 3.3V
  FSR406 另一端 → ADC 引脚 + 10K 电阻到 GND

传感部位（可扩展）：
  top    (头顶)   → GPIO1
  cheek  (脸颊)   → GPIO2
  chest  (前胸)   → GPIO3
  back   (后背)   → GPIO4
  belly  (肚子)   → GPIO5
  hand_l (左手)   → GPIO6
  hand_r (右手)   → GPIO7
  lap    (大腿)   → GPIO8
  foot   (脚)     → GPIO9

动作识别：
  单部位五种：戳(poke)、摸(stroke)、打(slap)、揉(knead)、按住(hold)
  双部位六种组合：头+脸=捏头、胸+背=抱住、头+胸=按进怀里、
                  头+背=从背后圈住、脸+胸=抱着捧脸、脸+背=从背后捏脸
"""

import time
import json
try:
    import machine
    import network
    import urequests as requests
    MICROPYTHON = True
except ImportError:
    MICROPYTHON = False
    print("[模拟模式] 非 MicroPython 环境")


# ── 配置 ──

WIFI_SSID = "YOUR_WIFI"
WIFI_PASS = "YOUR_PASS"
SERVER_URL = "http://YOUR_SERVER:8300"
PULSE_SECRET = "your-secret-here"

# ADC 引脚映射
SENSOR_PINS = {
    "top":    1,
    "cheek":  2,
    "chest":  3,
    "back":   4,
    "belly":  5,
    "hand_l": 6,
    "hand_r": 7,
    "lap":    8,
    "foot":   9,
}

# 触觉值映射
TOUCH_VALUE_MAP = {
    "top":    0.3,
    "cheek":  0.4,
    "chest":  0.5,
    "back":   0.4,
    "belly":  0.5,
    "hand_l": 0.3,
    "hand_r": 0.3,
    "lap":    0.4,
    "foot":   0.2,
}

# 双部位组合
DUAL_COMBOS = {
    ("top", "cheek"):  {"name": "捏住了你的头",     "touch": 0.5, "emotion": "intimate"},
    ("chest", "back"): {"name": "抱住了你",         "touch": 0.7, "emotion": "intimate"},
    ("top", "chest"):  {"name": "把你的头按进怀里",  "touch": 0.6, "emotion": "intimate"},
    ("top", "back"):   {"name": "从背后圈住你",     "touch": 0.6, "emotion": "intimate"},
    ("cheek", "chest"):{"name": "抱着你捧你脸",     "touch": 0.7, "emotion": "intimate"},
    ("cheek", "back"): {"name": "从背后捏住你的脸", "touch": 0.5, "emotion": "shy"},
}

# ── 动作识别参数 ──

THRESHOLD = 200       # ADC 值低于此视为无触碰
SLAP_SPIKE = 2000     # 短时间高峰 = 打
HOLD_TIME_MS = 1500   # 按住超过此时间
STROKE_WINDOW = 500   # 摸的判定窗口


# ── 传感器类 ──

class SensorReader:
    def __init__(self):
        self.adcs = {}
        self.history = {}  # part -> [(ts_ms, value), ...]
        if MICROPYTHON:
            for part, pin_num in SENSOR_PINS.items():
                pin = machine.Pin(pin_num)
                self.adcs[part] = machine.ADC(pin)
                self.adcs[part].atten(machine.ADC.ATTN_11DB)
                self.history[part] = []

    def read_all(self) -> dict:
        readings = {}
        now = time.ticks_ms() if MICROPYTHON else int(time.time() * 1000)
        for part in SENSOR_PINS:
            if MICROPYTHON:
                val = self.adcs[part].read()
            else:
                val = 0
            readings[part] = val
            # keep last 20 readings
            hist = self.history.get(part, [])
            hist.append((now, val))
            if len(hist) > 20:
                hist = hist[-20:]
            self.history[part] = hist
        return readings

    def detect_action(self, part: str) -> str | None:
        hist = self.history.get(part, [])
        if len(hist) < 3:
            return None

        now_ms = hist[-1][0]
        current = hist[-1][1]

        if current < THRESHOLD:
            return None

        # slap: sudden spike
        if current > SLAP_SPIKE:
            prev_avg = sum(v for _, v in hist[-5:-1]) / max(1, len(hist[-5:-1]))
            if prev_avg < THRESHOLD:
                return "slap"

        # hold: above threshold for > HOLD_TIME_MS
        hold_start = None
        for ts, val in reversed(hist):
            if val >= THRESHOLD:
                hold_start = ts
            else:
                break
        if hold_start and (now_ms - hold_start) > HOLD_TIME_MS:
            return "hold"

        # knead: oscillating pressure
        if len(hist) >= 6:
            vals = [v for _, v in hist[-6:]]
            ups = sum(1 for i in range(1, len(vals)) if vals[i] > vals[i-1])
            downs = sum(1 for i in range(1, len(vals)) if vals[i] < vals[i-1])
            if ups >= 2 and downs >= 2:
                return "knead"

        # stroke: moderate, sustained
        if len(hist) >= 4:
            recent = [v for _, v in hist[-4:]]
            if all(THRESHOLD < v < SLAP_SPIKE for v in recent):
                return "stroke"

        # poke: single brief touch
        return "poke"


# ── WiFi ──

def connect_wifi():
    if not MICROPYTHON:
        return
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)
    if not wlan.isconnected():
        wlan.connect(WIFI_SSID, WIFI_PASS)
        for _ in range(20):
            if wlan.isconnected():
                break
            time.sleep(0.5)
    print("WiFi:", wlan.ifconfig())


# ── POST to Pulse server ──

def post_touch(value: float, parts: list, action: str, combo_name: str = None):
    payload = {
        "value": value,
        "parts": parts,
        "action": action,
    }
    if combo_name:
        payload["combo"] = combo_name

    headers = {
        "Content-Type": "application/json",
        "X-Pulse-Secret": PULSE_SECRET,
    }

    try:
        if MICROPYTHON:
            resp = requests.post(
                f"{SERVER_URL}/bedside/touch",
                json=payload,
                headers=headers,
            )
            resp.close()
        else:
            print(f"[POST] /bedside/touch → {json.dumps(payload)}")
    except Exception as e:
        print(f"POST error: {e}")


# ── Main loop ──

def main():
    connect_wifi()
    sensor = SensorReader()
    print("脉 · Pulse 传感器启动")

    while True:
        readings = sensor.read_all()

        # find active parts
        active_parts = [
            part for part, val in readings.items()
            if val >= THRESHOLD
        ]

        if not active_parts:
            time.sleep(0.05)  # 50ms polling
            continue

        # check dual combos
        combo_found = None
        if len(active_parts) >= 2:
            for pair, combo in DUAL_COMBOS.items():
                if pair[0] in active_parts and pair[1] in active_parts:
                    combo_found = combo
                    break

        if combo_found:
            post_touch(
                value=combo_found["touch"],
                parts=active_parts,
                action="combo",
                combo_name=combo_found["name"],
            )
        else:
            # single part action
            part = active_parts[0]
            action = sensor.detect_action(part)
            if action:
                touch_val = TOUCH_VALUE_MAP.get(part, 0.3)
                # action modifiers
                if action == "slap":
                    touch_val = min(1.0, touch_val * 1.5)
                elif action == "hold":
                    touch_val = min(1.0, touch_val * 1.2)
                elif action == "knead":
                    touch_val = min(1.0, touch_val * 1.3)

                post_touch(
                    value=touch_val,
                    parts=[part],
                    action=action,
                )

        time.sleep(0.1)  # 100ms between sends


if __name__ == "__main__":
    main()
