# 语音条：让 Lumi 在 Claude 对话里发语音

基于 voice-card-mcp（单文件 Python MCP 服务，致谢 [garan0613/voice-mcp](https://github.com/garan0613/voice-mcp)，MIT）：Claude 调用 `voice_card` 工具，服务用 ElevenLabs 合成语音，在 claude.ai 对话里渲染成可播放的语音条卡片。

在原版基础上加了 **OAuth 登录**：claude.ai 添加自定义连接器时只能填 URL、不能填请求头，所以连接时会弹出授权页，输入密码即可。原版的 `Authorization: Bearer <MCP_AUTH_TOKEN>` 仍然可用。

和 [Ombre Brain](../ombre-brain/README.md) 部署在同一台服务器上，共用同一条 Cloudflare 隧道。

## 文件

- `voice_card_mcp.py`：服务端（原版 + OAuth 授权服务器 + 授权页）
- `install.template.sh`：安装脚本模板
- `build.sh`：把 `voice_card_mcp.py` 内嵌进模板，生成单文件的 `install.sh`
- `install.sh`：生成物，服务器上只需要这一个文件。改代码后重新跑 `bash build.sh`

## 部署

前提：Ombre Brain 已按它的 README 装好（Docker、`/opt/ombre-brain/cloudflared` 隧道凭据都在）。

1. 把 `install.sh` 弄到服务器上（仓库临时公开后用一条命令下载，或 OrcaTerm 上传），运行：

   ```bash
   sudo bash install.sh
   ```

   它会：在 `/opt/voice-card` 构建并启动容器（只绑 `127.0.0.1:18002`）；首次生成 `.env`（随机授权密码 `OAUTH_PASSWORD`、静态 Token，音色默认 Lumi）；把 `voice.gpt1126.top` 加进隧道，并把 cloudflared 改成用 `config.yml` 同时转发两个域名。

2. 去 ElevenLabs 后台建一个 API Key：**只开 Text to Speech 权限，设每月额度上限**。然后：

   ```bash
   sudo bash install.sh --set-key
   ```

   粘贴 Key 回车（屏幕不显示）。它会写入 `.env`、重启服务，并合成一句测试语音：输出 `OK: https://voice.gpt1126.top/audio/...mp3` 就是成功；输出 `ERROR`/`FAIL` 说明 Key 或网络有问题。

3. 验证：浏览器打开 `https://voice.gpt1126.top/healthz`，应看到 `"ok":true` 和 `"oauth":true`。

4. claude.ai → 设置 → 连接器 → 添加自定义连接器：名称 `Lumi Voice`，URL `https://voice.gpt1126.top/mcp` → 继续 → 弹出「授权 Claude 使用语音条」页面，输入授权密码：

   ```bash
   sudo grep OAUTH_PASSWORD /opt/voice-card/.env
   ```

## 使用

在 claude.ai 对话里让 Claude「用语音跟我说……」，它会调用 `voice_card`，对话里出现语音条，点播放就能听。语音卡片是 claude.ai 的 MCP Apps 功能，Claude Code 界面里不一定显示。

## 维护

```bash
cd /opt/voice-card
sudo docker compose logs -f --tail 100   # 看日志
sudo bash ~/install.sh --test            # 再合成一句测试
sudo bash ~/install.sh                   # 更新（.env、授权状态、音频都保留）
```

- 授权状态（已注册的客户端、令牌）存在 `/opt/voice-card/data/oauth.json`，删掉它再重启就会让所有已连接的客户端重新授权
- 生成的音频在 `/opt/voice-card/audio`，默认保留 7 天（`AUDIO_KEEP_DAYS`）
- 换音色：改 `.env` 里的 `ELEVENLABS_VOICE_ID`，`sudo docker compose up -d --force-recreate`
