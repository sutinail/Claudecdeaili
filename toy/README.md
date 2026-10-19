# Toy Bridge

不用电脑：iPhone 上的 Bluefy 网页同时负责蓝牙连接和「桥接」。

```
AI（Claude Code 等）
  → Supabase 命令信箱（device_commands）
  → iPhone · Bluefy 打开的 index.html（每秒领取一次命令）
  → Web Bluetooth
  → Toy
```

| 文件 | 用途 |
|---|---|
| `index.html` | 手机端页面：连接蓝牙、手动控制、接收 AI 指令、紧急停止、调试协议 |
| `supabase.sql` | 建表和 RPC 函数（带 token 校验、过期、原子领取、参数校验） |
| `send.sh` | AI 端投递命令并等待结果 |

## 一、Supabase（一次性）

1. 新建一个 Supabase 项目。
2. SQL Editor 里运行 `supabase.sql` 全部内容。
3. 生成一串长随机字符串作为 bridge token，运行文件末尾那条 `insert`（把占位字符串换成你的 token）。
4. 在 Project Settings → API 里记下 **Project URL** 和 **anon / publishable key**。

表本身对 anon 完全关闭，只能通过带 token 的函数访问。anon key 泄露了也没用，**token 不要泄露**。

## 二、手机端

1. 把 `index.html` 放到任意 HTTPS 地址（Web Bluetooth 要求 HTTPS）：
   GitHub Pages、Cloudflare Pages、Netlify Drop（直接拖文件）都可以。
2. iPhone 上用 **Bluefy** 打开这个地址。
3. 「设置」里填 URL / anon key / token，调好**强度上限**，保存。
4. 点「连接 Toy」，选你的设备。
5. 先用手动滑块从低强度试；能动了再打开「AI 联动」。

使用时页面要停在前台、屏幕别锁。默认切到后台会自动全部停止。

## 三、协议

内置预设来自 [buttplug.io](https://github.com/buttplugio/buttplug) 的开源设备库（BSD-3-Clause），
Svakom 全系都用服务 `ffe0` / 特征 `ffe1`。连接时会按蓝牙设备名自动匹配。

设备名不在列表里时：

1. 先试「分体吸震 · 猜测 A / B」，强度上限调到 10–20%。
2. 都不动，就打开「调试 / 找协议」：列出服务和特征、订阅通知、手动发十六进制试帧。
3. 试出来以后，预设选「自定义」，在设置里写 JSON：

```json
{
  "label": "我的 Toy",
  "service": "0000ffe0-0000-1000-8000-00805f9b34fb",
  "tx": "0000ffe1-0000-1000-8000-00805f9b34fb",
  "withResponse": false,
  "channels": {
    "vibration": { "label": "震动", "max": 10, "frame": "55 03 00 00 {on} {v} 00" },
    "suction":   { "label": "吸吮", "max": 5,  "frame": "55 09 00 00 {v} 00 00" }
  }
}
```

`{v}` 档位（0..max），`{v+1}` 档位加一，`{on}` 有强度为 `01` 否则 `00`，`{on:05}` 有强度为 `05`。

### 已验证：Svakom SL278B 分欣（分体款）

两件是两台同名的 SL278B 蓝牙设备，页面里两件都连上即可。数据来自官方 App 的 HCI 抓包：

| 功能 | 由哪件执行 | 指令 | 停止 |
|---|---|---|---|
| 吸吮 | 吸吮蛋 | `55 09 00 00 <模式1-5> <强度1-10> 00` | `55 09 00 00 00 00 00` |
| 震动 | 震动棒 | `55 03 00 00 <模式1-10> <强度1-10> 00` | `55 03 00 00 00 00 00` |
| 伸缩 | 震动棒 | `55 08 00 00 <花样1-7> 00 00` | `55 08 00 00 00 00 00` |

连接后先订阅 FFE2 通知，再发 `55 02 00 00 00 00 00`、`55 04 00 00 00 00 aa`。
`55 04 00 00 00 <时长> aa` 会让设备「滋滋」一下，官方 App 用来提示已连接，页面不发。

## 四、AI 端

```bash
export TOY_SUPABASE_URL=https://xxxx.supabase.co
export TOY_ANON_KEY=...
export TOY_TOKEN=...

toy/send.sh status
toy/send.sh pulse vibration 30 20 wave
toy/send.sh combo '{"suction":{"intensity":30,"duration_seconds":20},"vibration":{"pattern":"pulse","intensity":25,"duration_seconds":30}}'
toy/send.sh stop
```

- `intensity` 0–100（百分比，手机端还会再压到你设的上限）
- `duration_seconds` 0–600（同样受手机端上限约束）
- `pattern`：`steady` 持续 / `pulse` 脉冲 / `wave` 波浪 / `escalate` 渐强
- `channel`：`vibration` 震动 / `suction` 吸吮 / `thrust` 伸缩（强度换算成花样 1–7，pattern 固定为持续）
- 命令默认 90 秒内没被领取就过期，不会在网络恢复后突然执行

## 安全

- 页面底部的「停止」随时可按；蓝牙断开、页面进后台都会清零。
- 强度和时长有三层限制：数据库校验 → 页面校验 → 页面上限。
- 不要把 token、anon key、真实设备地址提交到公开仓库。
