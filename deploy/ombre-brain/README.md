# 在自有 VPS 上部署 Ombre Brain

[Ombre Brain](https://github.com/P0luz/Ombre-Brain) 是给 Claude 用的长期记忆系统（MCP 服务）。这里的 `install.sh` 用官方 Docker 镜像把它装到你的 VPS 上，数据存在服务器本地磁盘，重启不丢。

下面是 2026-10-18 在**腾讯云上海轻量服务器（Ubuntu，2 核 4G）**上实际走通的步骤：全程在电脑浏览器 + 腾讯云 OrcaTerm 网页终端里完成，不需要 SSH 客户端，也不需要绑外币银行卡。

## 0. 准备

- 一台 Linux VPS（1 核 / 1GB 内存起步；要用本地向量模型 bge-m3 需再多 2–3GB 内存）
- 一个托管在 Cloudflare 的域名（免费账号即可，用来拿 HTTPS 地址给 Claude 连接）
- 一个模型 API Key：国内服务器用 [硅基流动](https://cloud.siliconflow.cn)（手机号注册，有免费额度），海外可用 Google AI Studio。装完再填也行

> ⚠️ 全程会出现三样「钥匙」：Dashboard 密码、MCP Token、模型 API Key（`sk-` 开头）。**都不要截图外发、不要贴进聊天**；万一发出去了，按文中的方法换一个新的即可。

## 1. 一键安装

在腾讯云控制台点服务器的「OrcaTerm 登录」，打开网页终端。

`install.sh` 是单文件、自包含的（compose 配置内嵌在里面），服务器上不需要访问 GitHub 源码。把它弄到服务器上，任选一种：

- **仓库临时公开 + 一条命令**（实际用的方式）：GitHub 仓库 Settings → 最底部 Danger Zone → Change visibility → Make public，然后在 OrcaTerm 里运行（`<commit>` 换成要用的提交号或分支名）：

  ```bash
  cd ~ && (curl -fsSL https://cdn.jsdelivr.net/gh/sutinail/Claudecdeaili@<commit>/deploy/ombre-brain/install.sh -o install.sh || curl -fsSL https://raw.githubusercontent.com/sutinail/Claudecdeaili/<commit>/deploy/ombre-brain/install.sh -o install.sh) && sudo bash install.sh
  ```

  脚本开始运行后就可以把仓库改回私有（Change to private）。
- **OrcaTerm 文件上传**：把 `install.sh` 传到家目录，再 `sudo bash ~/install.sh`
- **电脑上 scp**：`scp deploy/ombre-brain/install.sh <用户>@<服务器IP>:~`

脚本会：

1. 自动判断国内 / 海外网络（Docker Hub 连不上就按国内处理，也可以用 `OMBRE_CN=1` 强制）
2. 没有 Docker 就安装：国内走系统 apt 源（腾讯云已内置镜像），不够再用腾讯云 docker-ce 镜像源；海外走 get.docker.com
3. 国内额外配置 Docker Hub 加速 `https://mirror.ccs.tencentyun.com`（腾讯云内网可用；合并进已有的 `/etc/docker/daemon.json`）
4. 在 `/opt/ombre-brain` 写入 `docker-compose.yml`（基于官方 `deploy/docker-compose.user.yml`）
5. 第一次运行时生成 `/opt/ombre-brain/.env`：随机 Dashboard 密码、随机 MCP 静态 Token，鉴权模式 `hybrid`（OAuth + 静态 Token 共存），端口只绑 `127.0.0.1:18001`；国内默认把模型配成硅基流动（`deepseek-ai/DeepSeek-V3` 打标 + `BAAI/bge-m3` 向量化），因为国内服务器连不上 Gemini
6. 拉镜像、启动、等 `/health` 返回 ok，最后在屏幕上打印密码和 Token

看到「Ombre Brain 已启动 ✅」就成功了。**截图前务必遮住密码和 Token 两行**，或者运行 `clear` 清屏。

以后要查看密码 / Token（看完别截图）：

```bash
sudo grep -E 'PASSWORD|MCP_TOKEN' /opt/ombre-brain/.env
```

### 密码或 Token 泄露了怎么换

生成新的随机值写进 `.env` 并重建容器，新值不会显示在屏幕上（密码以 `.env` 为准，旧的立即失效）：

```bash
cd /opt/ombre-brain && sudo sed -i "s/^OMBRE_DASHBOARD_PASSWORD=.*/OMBRE_DASHBOARD_PASSWORD=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 24)/; s/^OMBRE_MCP_TOKEN=.*/OMBRE_MCP_TOKEN=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 48)/" .env && sudo docker compose up -d --force-recreate
```

## 2. 拿公网 HTTPS 地址（Cloudflare 命名隧道，命令行方式）

Claude.ai 网页版、手机 App 和云端 Claude Code 都需要一个 `https://` 地址。这里用 cloudflared 命令行建隧道：**只需要在浏览器里点一次授权，不用开通 Zero Trust，也不用绑卡**（Zero Trust 控制台那条路会要求绑卡）。服务器是主动往外连 Cloudflare，腾讯云防火墙不用开任何端口，国内服务器也不用 ICP 备案。

以下以域名 `gpt1126.top`、子域名 `ombre.gpt1126.top` 为例，换成你自己的。

### 2.1 让服务器登录 Cloudflare

```bash
sudo mkdir -p /opt/ombre-brain/cloudflared && sudo chown 65532:65532 /opt/ombre-brain/cloudflared && sudo docker run --rm -it -v /opt/ombre-brain/cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared:latest tunnel login
```

屏幕会打印一个 `https://dash.cloudflare.com/argotunnel?...` 开头的长网址，并显示 `Waiting for login...`。**终端别关**，把整条网址复制到电脑浏览器打开 → 点你的域名 → **Authorize**。回到终端看到 `You have successfully logged in` 即可。

> Cloudflare 登录后如果弹出「设置两步验证」，可以先点 Skip for now，事后再回来开（推荐开）。
> 手机浏览器打开 Cloudflare 后台如果一直提示「此页面已有新版本，请刷新」，多半是浏览器自动翻译导致的，换电脑浏览器即可。

### 2.2 创建隧道、绑定子域名、后台运行

```bash
D=/opt/ombre-brain/cloudflared; CF="sudo docker run --rm -v $D:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"; $CF tunnel create ombre && $CF tunnel route dns ombre ombre.gpt1126.top && sudo docker run -d --name cloudflared --restart unless-stopped --network host -v $D:/home/nonroot/.cloudflared cloudflare/cloudflared:latest tunnel --no-autoupdate --protocol http2 run --url http://localhost:18001 ombre
```

成功时依次看到 `Created tunnel ombre with id ...`、`Added CNAME ombre.gpt1126.top ...`，最后一行是一长串容器 ID。隧道凭据存在 `/opt/ombre-brain/cloudflared/`，容器设了自动重启，服务器重启后隧道会自己恢复。

### 2.3 告诉 Ombre Brain 它的公网地址

OAuth 授权要用到这个地址，不填的话 Claude 连接时可能被拒：

```bash
sudo sed -i 's#^  public_url: ""#  public_url: "https://ombre.gpt1126.top"#' /opt/ombre-brain/buckets/config.yaml && grep public_url /opt/ombre-brain/buckets/config.yaml && cd /opt/ombre-brain && sudo docker compose restart
```

应显示 `public_url: "https://ombre.gpt1126.top"`。

### 2.4 验证

浏览器打开 `https://ombre.gpt1126.top/health`，看到 `{"status":"ok"}` 就通了；打开 `https://ombre.gpt1126.top` 会出现 Ombre Brain 登录页。刚建的域名偶尔要等一两分钟生效。

## 3. 登录 Dashboard、填模型 Key

1. 浏览器打开 `https://ombre.gpt1126.top`，用 Dashboard 密码登录（第 1 步里查看密码的命令）
2. 去硅基流动「API 密钥」页新建一个 Key（`sk-` 开头）
3. Dashboard 首页有「N 项需处理」的红点列表（v3.6.14 没有单独的「引擎」标签页）：
   - **压缩 / 打标 LLM** → 右边「前往处理」→ 服务商预设已是硅基流动（DeepSeek-V3），在 API Key 栏粘贴 Key →「保存」→「测试」，出现「API Key 有效 ✓」。顺手把 **Max Tokens 改成 4096**（太小会截断 JSON、导致分类出错）再保存
   - **向量化 Embedding** → 「前往处理」→ 粘贴同一个 Key →「保存」→「测试」，出现「向量化连接成功（模型 BAAI/bge-m3，维度 1024）」
4. 如果向量化信息框里的维度还显示默认的 `3072`，在向量库还空的时候点右上角「重启」一次即可；已有记忆后若提示 OB-W005 维度不一致，按 Dashboard 提示「重算」
5. 首页其余提示：「实际生效配置：环境变量覆盖已保存设置」是安装脚本预设的硅基流动配置，正常；「GitHub 备份」可以以后再开；顶部「没有任何记忆」点「忽略」

## 4. 接到 Claude 上

只需要添加一个连接器，地址是 `https://ombre.gpt1126.top/mcp`。

- **Claude.ai 网页版 / 手机 App**：头像 → 设置 → 连接器 → 添加自定义连接器，名字填 `Ombre Brain`，URL 填上面的地址 → 连接 → 在弹出的 Ombre Brain 授权页输入 Dashboard 密码。成功后连接器里会列出 `Breath`、`Hold`、`Grow` 等 16 个工具。claude.ai 上接好后，云端 Claude Code 会话里也能直接用
- **本地 Claude Code**：

  ```bash
  claude mcp add ombre-brain --transport http https://ombre.gpt1126.top/mcp
  ```

- **只支持固定 Token 的客户端**：请求头带 `Authorization: Bearer <OMBRE_MCP_TOKEN>`

接上以后，[heartbeat skill](../../.claude/skills/heartbeat/SKILL.md) 里「记忆整理」那几项任务就会生效。

## 日常维护

```bash
cd /opt/ombre-brain

# 看日志
sudo docker compose logs -f --tail 100
sudo docker logs --tail 50 cloudflared

# 更新到最新版（重跑安装脚本即可，.env 和记忆不会被覆盖）
sudo bash ~/install.sh

# 备份：记忆、config.yaml、隧道凭据都在这个目录
sudo tar czf ombre-backup-$(date +%F).tar.gz -C /opt/ombre-brain buckets cloudflared .env
```

Dashboard 里也有带 SHA-256 校验的导出 / 导入功能。

### 其他方式（没走过，备查）

- **SSH 端口转发打开 Dashboard**（不经公网）：`ssh -L 18001:127.0.0.1:18001 <用户>@<服务器IP>`，浏览器访问 `http://localhost:18001`
- **Zero Trust 控制台建隧道**：Networks → Tunnels → Create a tunnel → Docker，拿 `eyJ...` token，在 Dashboard「设置 → Cloudflare Tunnel」里启动，Public Hostname 填 `localhost:8000`。需要开通 Zero Trust（可能要求绑卡）
- **nginx / Caddy 反代**：见官方 README「从源码部署」一节；国内服务器直连 80/443 需要域名 ICP 备案。不要把端口直接改成 `0.0.0.0` 暴露出去
