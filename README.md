# Claudecdeaili
## Skills

- [`heartbeat`](.claude/skills/heartbeat/SKILL.md) — 让 Claude 每 50 分钟醒来一次，你不在时自己找一件事做并留便签。改编自 [reneyuxi0402/claude-cant-sleep](https://github.com/reneyuxi0402/claude-cant-sleep)（MIT）。说「heartbeat」或「心跳」启动，说「停止心跳」停止。
- 审美四件套（都是 MIT，原样拷进来的，没改内容）：
  - [`aesthetic-foundations`](.claude/skills/aesthetic-foundations/SKILL.md) — 眼睛：把绘画、摄影、东方审美的判断力塞进设计评审。来自 [caoxg/claude-skill-aesthetic-foundations](https://github.com/caoxg/claude-skill-aesthetic-foundations)@359695c
  - [`web-design-engineer`](.claude/skills/web-design-engineer/SKILL.md) — 风格：garden-skills 里的网页设计 skill，带 style-recipes 风格配方库。来自 [ConardLi/garden-skills](https://github.com/ConardLi/garden-skills)@ce64df6
  - [`ckw-design`](.claude/skills/ckw-design/SKILL.md) — 纪律：先渲染再交给独立评审挑错，含 design-thinking / system / spatial / ux / philosophy 子 skill。来自 [connerkward/ckw-design-skill](https://github.com/connerkward/ckw-design-skill)@c8de7c8
  - [`brandmd`](.claude/skills/brandmd/SKILL.md) — 借光：`npx brandmd <网址>` 把 Stripe、Linear 这类真实站点的设计系统抽成 DESIGN.md。来自 [yuvrajangadsingh/brandmd](https://github.com/yuvrajangadsingh/brandmd)@b79a8a9

## Deploy

- [`deploy/ombre-brain`](deploy/ombre-brain/README.md) — 在自有 VPS 上一键部署 [Ombre Brain](https://github.com/P0luz/Ombre-Brain) 长期记忆系统（Docker + Cloudflare Tunnel），给 Claude 接上跨会话记忆。
- [`deploy/lumi-web`](deploy/lumi-web/README.md) — Lumi 的自建前端：手机主屏 App，脑子是服务器上的 Claude Code，接 Ombre Brain、Pulse 和语音条，聊天记录存在服务器上。
