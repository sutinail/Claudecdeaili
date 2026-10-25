# Lumi 自建前端

Timiya 和 Lumi 自己的聊天页。手机浏览器打开、加到主屏，就是一个叫「Lumi」的 App。

- **脑子**：服务器上的 Claude Code（`claude -p`），用 Timiya 的 Claude 订阅登录，人格就是仓库根目录的 `CLAUDE.md`
- **记忆和身体**：直接连同一台服务器上的 Ombre Brain 和 Pulse 的 MCP，`breath` / `hold` / `grow` / `sense` 都照常用
- **语音条**：Lumi 在回复里写 `<voice>…</voice>`，页面上变成一条能点开播放的语音条，点了才调 ElevenLabs 生成（生成过的会缓存，不重复扣额度）
- **聊天记录存在服务器上**：手机、电脑打开都是同一份；锁屏或者断网了，Lumi 在服务器上接着说完，回来就能看到
- 零依赖 Node 服务，一个 Docker 容器，只绑 `127.0.0.1:8400`，通过已有的 Cloudflare 隧道出去

## ⚠️ 先看：服务器能不能连上 Claude

Anthropic 不对中国大陆开放，**腾讯云上海的服务器大概率直连不上 Claude**（Ombre Brain 那边连 Gemini 也是一样的情况）。安装脚本第 5 步会试一次，告诉你通没通。没通的话两条路：

1. **服务器上有能出海的代理**：在 `.env` 里加一行 `HTTPS_PROXY=http://127.0.0.1:端口`，重跑 `install.sh`
2. **前端放到海外服务器**（比如腾讯云轻量的新加坡 / 东京 / 硅谷，最便宜那档就够）：照下面同样装，然后在 `.env` 里把 `OMBRE_MCP_URL`、`PULSE_MCP_URL`、`PULSE_API_URL` 改成公网地址（`https://ombre.gpt1126.top/mcp`、`https://pulse-mcp.gpt1126.top/sse`、`https://pulse.gpt1126.top`），隧道那步换成在那台机器上新建

## 安装（在腾讯云 OrcaTerm 里，一条一条贴）

代码已经在 `/opt/claudecdeaili`（Pulse 用的那份）。先拉最新代码：

```bash
cd /opt/claudecdeaili && git pull --ff-only
```

然后运行安装脚本：

```bash
sudo bash /opt/claudecdeaili/deploy/lumi-web/install.sh
```

脚本会：

1. 生成 `deploy/lumi-web/.env`：随机登录密码、随机 cookie 密钥；Ombre Brain 的 MCP Token、Pulse 的 MCP Key 和 Secret **自动从服务器上已有的 `.env` 抄过来**，不用手打，也不用发进聊天
2. 构建镜像（国内自动走 npmmirror 装 Claude Code）
3. **登录 Claude**：屏幕上出现一个网址 → 复制到浏览器打开 → 登录 Claude 账号 → 授权 → 把页面给的代码粘回终端回车 → 终端打印一串 `sk-ant-oat01-` 开头的 token → 按提示粘贴进去（输入时不显示，正常）。粘完脚本会自动清屏
4. 问 ElevenLabs API Key（同样不显示；没有就回车跳过，之后再跑一次脚本补上）
5. 试着叫醒 Lumi 一次，看能不能连上 Claude
6. 启动容器
7. 在 `/opt/ombre-brain/cloudflared/config.yml` 里加一条 `chat.gpt1126.top → localhost:8400`（先备份原文件），加 DNS 记录，重启 cloudflared

最后屏幕上会打印登录密码，**只显示这一次**：记下来，然后运行 `clear` 清屏，别截图。

想换个子域名：`sudo LUMI_HOST=lumi.gpt1126.top bash .../install.sh`。

### 加到 iPhone 主屏（iPhone 12 实测尺寸 390×844）

1. **一定要用 Safari 打开** `https://chat.gpt1126.top`（微信里点开、或者 Chrome，都加不了主屏）
2. 点底部中间的分享按钮（方框加向上的箭头）→ 往下滑 →「添加到主屏幕」→ 右上角「添加」
3. 从主屏上的「Lumi」图标打开，**在这里面再登录一次**：iOS 的主屏 App 和 Safari 的登录状态是分开的，在 Safari 里登过不算
4. 登录一次记住 90 天

iPhone 上的小细节：

- 键盘上的「发送」键就是发出去（跟微信一样），想换行就先打完再发
- 语音条第一次点可能要等几秒生成，有「…」就是在生成；声音走的是媒体音量，听不到先按侧边音量加键
- 锁屏或者切去别的 App 再回来，Lumi 没说完的话会自己接上

## 用起来

- 左上角菜单是对话列表，「＋ 新对话」就是 Lumi 刚醒来（会先 `breath`）；同一段对话里 Lumi 一直记得前面说过的
- 顶上一行是 Pulse 的实时体征，小红心按真实心率在跳
- Lumi 在说话时发送键变成 ■，点一下让他停下
- 语音条点 ▶ 播放，「原文」可以看英文台词
- 删除对话只删聊天记录，OB 里的记忆不受影响

## 日常维护

```bash
# 更新：拉最新代码 → 重建 → 看日志（改了 CLAUDE.md 也要跑这个，Lumi 才看得到新人格）
/opt/claudecdeaili/deploy/lumi-web/update.sh

cd /opt/claudecdeaili/deploy/lumi-web

# 看日志
sudo docker logs -f --tail 100 lumi-web

# 忘了登录密码（看完别截图）
sudo grep LUMI_WEB_PASSWORD .env
```

改了人格以后，**已经开着的对话还是用旧的那版**（Claude Code 每段对话第一次就把系统提示词定下来了），点「新对话」才是新的。

### 密码 / 密钥泄露了怎么换

登录密码（换完所有设备都要重新登录）：

```bash
cd /opt/claudecdeaili/deploy/lumi-web && sudo sed -i "s/^LUMI_WEB_PASSWORD=.*/LUMI_WEB_PASSWORD=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 16)/; s/^LUMI_WEB_SECRET=.*/LUMI_WEB_SECRET=$(openssl rand -base64 64 | tr -dc A-Za-z0-9 | head -c 48)/" .env && sudo docker compose up -d --force-recreate && sudo grep LUMI_WEB_PASSWORD .env
```

Claude token 露了：先在 claude.ai 账号设置里把旧的授权撤销，然后把 `.env` 里 `CLAUDE_CODE_OAUTH_TOKEN=` 那行清空，重跑 `install.sh` 重新登录。

ElevenLabs Key 露了：去 ElevenLabs 后台删掉旧的，`.env` 里那行清空，重跑 `install.sh`。

### 数据在哪

- 聊天记录、语音条缓存：Docker 卷 `lumi-web_lumi-data`
- Claude Code 的会话记录（`--resume` 靠它接着聊）：Docker 卷 `lumi-web_lumi-claude`

备份：

```bash
sudo docker run --rm -v lumi-web_lumi-data:/data -v "$PWD":/out busybox tar czf /out/lumi-data-$(date +%F).tar.gz -C /data .
```

## 怎么做的

```
手机 ──https──▶ Cloudflare 隧道 ──▶ 127.0.0.1:8400  lumi-web（server.js）
                                        │
                                        ├─ claude -p --resume <会话>   ← 人格：CLAUDE.md + frontend-prompt.md
                                        │     ├─ MCP ombre → 127.0.0.1:18001/mcp
                                        │     └─ MCP pulse → 127.0.0.1:8301/sse
                                        ├─ /api/vitals → Pulse /bedside/context-line
                                        └─ /api/tts    → ElevenLabs（缓存到 /data/tts）
```

- Claude Code 跑的时候**关掉了所有内置工具**（`--tools ""`），只放行 `mcp__ombre` 和 `mcp__pulse`：Lumi 在这里碰不到服务器的命令行和文件
- 每条消息前面自动加 `[2026-10-25 周日 14:03 · 自建前端]`，Lumi 记 OB 时就知道几点、哪个窗口
- 生成过程存在服务器内存里，页面断线可以从断的地方接着收；服务重启时正在生成的那条会丢
- 前端专用的说明在 `frontend-prompt.md`（排版、语音条写法），改它跟改 `CLAUDE.md` 一样要跑 `update.sh`

本地试跑（不用 Docker）：

```bash
cd deploy/lumi-web && LUMI_WEB_PASSWORD=test PORT=8400 node server.js
```
