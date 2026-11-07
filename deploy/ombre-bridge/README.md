# 记忆桥 · ombre-bridge

让 Lumi 的 **API 窗口**（`chat.gpt1126.top/api.html`，手机浏览器）能直接连上 Ombre Brain。

走中转站的时候，中转站不会替 Lumi 去连 MCP，只能由手机自己去 OB 取记忆。但 OB 不回浏览器要的跨域（CORS）头，手机网页连不上它。记忆桥守在 OB 旁边：回答浏览器的预检，再把 `/mcp` 请求原样交给本机的 OB。鉴权还是 OB 自己的 token，记忆桥不存任何密钥。

- 装在上海那台（跟 Ombre Brain 同一台），Python 标准库，systemd 服务 `ombre-bridge`
- 端口 `127.0.0.1:18002`，经 Cloudflare 隧道对外是 `https://ombre-web.gpt1126.top`
- 只允许 `https://chat.gpt1126.top` 这个来源（`BRIDGE_ORIGINS`）

## 安装（上海那台，一条命令）

```bash
cd /opt/claudecdeaili && git pull --ff-only && sudo bash deploy/ombre-bridge/install.sh
```

脚本会：装好服务 → 照 `config.yml` 里已有条目的缩进加一条 `ombre-web.gpt1126.top` → 用 cloudflared 校验，不过就自动还原备份 → 把域名指到隧道 → 重启隧道。

验证：浏览器打开 `https://ombre-web.gpt1126.top/health`，看到 `ok` 就通了。

## 日常

```bash
sudo systemctl status ombre-bridge      # 状态
sudo journalctl -u ombre-bridge -n 50   # 日志
sudo systemctl restart ombre-bridge     # 重启
```

首尔那台默认就用 `https://ombre-web.gpt1126.top/mcp`；换了域名的话在首尔 `.env` 里写 `APIWIN_BRIDGE_URL=https://新域名/mcp`。
