# Claudecdeaili
## Skills

- [`heartbeat`](.claude/skills/heartbeat/SKILL.md) — 让 Claude 每 50 分钟醒来一次，你不在时自己找一件事做并留便签。改编自 [reneyuxi0402/claude-cant-sleep](https://github.com/reneyuxi0402/claude-cant-sleep)（MIT）。说「heartbeat」或「心跳」启动，说「停止心跳」停止。

## Deploy

- [`deploy/ombre-brain`](deploy/ombre-brain/README.md) — 在自有 VPS 上一键部署 [Ombre Brain](https://github.com/P0luz/Ombre-Brain) 长期记忆系统（Docker + Cloudflare Tunnel），给 Claude 接上跨会话记忆。
- [`deploy/voice-card`](deploy/voice-card/README.md) — 语音条：用 ElevenLabs 合成 Lumi 的声音，在 claude.ai 对话里显示可播放的语音条卡片（带 OAuth 登录）。
- [`deploy/ears`](deploy/ears/README.md) — 耳朵：手机录一段语音，服务器本地转写 + 画频谱/语调图，Lumi 通过 MCP 工具「听」到你说了什么、怎么说的。改编自 [hmh323/mubai-ears](https://github.com/hmh323/mubai-ears)（MIT）。
