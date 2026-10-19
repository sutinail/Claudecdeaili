# 耳朵：让 Lumi 听见你的语音

Claude 读不了音频，但能读图、读数字、读文字。这台服务把你发来的语音变成三样东西，通过 MCP 工具交给 Claude：

- **说了什么**：本地 Whisper 转写，带时间戳的文字
- **怎么说的**：音高范围、句尾上扬还是下沉、停顿在哪、响度、语速，外加一条基频曲线
- **一张图**：上半是梅尔频谱（照人耳频率感知），下半红线是语调、蓝色是响度、黄带是停顿

耳蜗（频谱 + 韵律）和速记（本地 Whisper）的做法来自 [hmh323/mubai-ears](https://github.com/hmh323/mubai-ears)（MIT）。原版是电脑上的命令行工具；这里把它改成跑在自己服务器上的 MCP 服务，加了手机录音页和 OAuth 登录，手机上就能用。

**音频、转写、频谱图都只在你自己的服务器上。** 唯一的外部下载是第一次从 Hugging Face 镜像拉一次 Whisper 模型权重。

和 [Ombre Brain](../ombre-brain/README.md)、[语音条](../voice-card/README.md) 部署在同一台服务器上，共用同一条 Cloudflare 隧道。

## 怎么用

1. 手机浏览器打开 `https://ears.gpt1126.top`，第一次输入密码（30 天内这台手机不用再输）。可以把它「添加到主屏幕」，用起来像个 App
2. 按一下大圆按钮开始录，再按一下发送；或者点「上传一段录音」选一个文件（iPhone 语音备忘录导出的 m4a、mp3、wav 都行）
3. 页面显示「✅ 听完了」后，回 claude.ai 对 Lumi 说「听听我的语音」，Lumi 会调用 `listen` 工具

> QQ / 微信导出的语音多是 silk / amr 格式，要先用转换工具转成 mp3 / wav 再上传。

## 文件

- `ears_mcp.py`：服务端（耳蜗 + 速记 + 录音页 + OAuth + MCP 工具 `listen` / `list_voice_messages`）
- `install.template.sh`：安装脚本模板
- `build.sh`：把 `ears_mcp.py` 内嵌进模板，生成单文件的 `install.sh`
- `install.sh`：生成物，服务器上只需要这一个文件。改代码后重新跑 `bash build.sh`

## 部署

前提：Ombre Brain 已按它的 README 装好（Docker、`/opt/ombre-brain/cloudflared` 隧道凭据都在）。

1. 把 `install.sh` 弄到服务器上（仓库临时公开后用一条命令下载，或 OrcaTerm 上传），运行：

   ```bash
   sudo bash install.sh
   ```

   它会：
   - 在 `/opt/ears` 构建并启动容器（只绑 `127.0.0.1:18003`）。第一次要下载 ffmpeg、中文字体和 Whisper 依赖，镜像约 1.6GB，国内服务器自动走腾讯云 apt / pip 镜像，大约 5–10 分钟
   - 首次生成 `.env`：随机密码 `OAUTH_PASSWORD`（录音页和连接器授权共用）、静态 Token
   - 经 hf-mirror 预先下载 Whisper `small` 模型（约 480MB）
   - 把 `ears.gpt1126.top` 加进隧道。只增不删，Ombre Brain 和语音条的域名不受影响

2. 验证：浏览器打开 `https://ears.gpt1126.top/healthz`，应看到 `"ok":true`、`"oauth":true`。

3. claude.ai → 设置 → 连接器 → 添加自定义连接器：名称 `Lumi ears`，URL `https://ears.gpt1126.top/mcp` → 继续 → 在弹出的「授权 Claude 使用耳朵」页面输入密码：

   ```bash
   sudo grep OAUTH_PASSWORD /opt/ears/.env
   ```

   看完别截图。手机录音页用的也是这个密码。

## 维护

```bash
cd /opt/ears
sudo docker compose logs -f --tail 100   # 看日志（每条语音处理完会打印一行）
sudo bash ~/install.sh                   # 更新（.env、授权状态、语音、模型都保留）
sudo bash ~/install.sh --warm            # 模型没下载成功时，单独再下载一次
```

- 语音存在 `/opt/ears/data/clips/`，每条一个目录（原始音频、频谱图、转写、摘要），默认保留 30 天（`.env` 里的 `CLIP_KEEP_DAYS`）
- 转写不准：`.env` 里把 `WHISPER_MODEL` 改成 `medium`（要 2GB+ 空闲内存，更慢），然后 `sudo docker compose up -d --force-recreate && sudo bash ~/install.sh --warm`
- 密码泄露了：改 `.env` 里的 `OAUTH_PASSWORD`，`sudo docker compose up -d --force-recreate`，手机录音页和 claude.ai 连接器都要重新输一次新密码。想让所有已连接的客户端失效，再删掉 `/opt/ears/data/oauth.json` 后重启
