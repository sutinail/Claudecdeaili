# 在自有 VPS 上部署 Ombre Brain

[Ombre Brain](https://github.com/P0luz/Ombre-Brain) 是给 Claude 用的长期记忆系统（MCP 服务）。这里的 `install.sh` 用官方 Docker 镜像把它装到你的 VPS 上，数据存在服务器本地磁盘，重启不丢。

## 0. 准备

- 一台 Linux VPS（1 核 / 1GB 内存起步；要用本地向量模型 bge-m3 需再多 2–3GB 内存）
- 能 SSH 登录，root 或有 sudo 权限
- 可选：一个托管在 Cloudflare 的域名（用来拿 HTTPS 地址给 Claude.ai 连接）
- 可选：LLM API Key。国内服务器用硅基流动，海外可用 Google AI Studio 免费额度。不填也能启动，之后在 Dashboard 里填

## 1. 一键安装

`install.sh` 是单文件、自包含的（compose 配置内嵌在里面），服务器上不需要访问 GitHub。本仓库是私有的，服务器没法直接 `curl` 它，所以先把这一个文件弄到服务器上，任选一种：

- **电脑上 scp**：`scp deploy/ombre-brain/install.sh <用户>@<服务器IP>:~`
- **腾讯云 OrcaTerm**：用 OrcaTerm 登录后，用它的文件上传功能把 `install.sh` 传到家目录
- **直接粘贴**：在服务器终端输入 `cat > ~/install.sh <<'EOF'`，回车，粘贴脚本全文，再单独一行输入 `EOF` 回车

然后在服务器上运行：

```bash
sudo bash ~/install.sh
```

脚本会：

1. 自动判断国内 / 海外网络（Docker Hub 连不上就按国内处理，也可以用 `OMBRE_CN=1` 强制）
2. 没有 Docker 就安装：国内走系统 apt 源（腾讯云已内置镜像），不够再用腾讯云 docker-ce 镜像源；海外走 get.docker.com
3. 国内额外配置 Docker Hub 加速 `https://mirror.ccs.tencentyun.com`（腾讯云内网可用；合并进已有的 `/etc/docker/daemon.json`）
4. 在 `/opt/ombre-brain` 写入 `docker-compose.yml`（基于官方 `deploy/docker-compose.user.yml`）
5. 第一次运行时生成 `/opt/ombre-brain/.env`：随机 Dashboard 密码、随机 MCP 静态 Token，鉴权模式 `hybrid`（OAuth + 静态 Token 共存），端口只绑 `127.0.0.1:18001`；国内默认把模型配成硅基流动（`deepseek-ai/DeepSeek-V3` 打标 + `BAAI/bge-m3` 向量化），因为国内服务器连不上 Gemini
6. 拉镜像、启动、等 `/health` 返回 ok，最后打印密码和 Token

查看密码和 Token：

```bash
sudo grep -E 'PASSWORD|MCP_TOKEN' /opt/ombre-brain/.env
```

> `.env` 里是万能钥匙，别提交到 git、别截图发出去。

### 腾讯云 / 国内服务器注意

- 模型 API Key：去 [硅基流动](https://siliconflow.cn/) 注册拿 key，填在 Dashboard「③ 引擎」里（打标和向量化可以用同一个 key）。`BAAI/bge-m3` 免费，DeepSeek-V3 按量计费、很便宜；想全免费可以在 Dashboard 里把打标模型换成免费的小模型
- 腾讯云防火墙不用开任何端口：Cloudflare Tunnel 是服务器主动往外连
- 不用 Tunnel、改用自己的域名 + nginx 直连 80/443 的话，国内服务器的域名必须先 ICP 备案

## 2. 打开 Dashboard

服务只监听服务器本机，所以用 SSH 端口转发从你自己电脑访问：

```bash
ssh -L 18001:127.0.0.1:18001 <用户>@<服务器IP>
```

保持这个 SSH 连接，浏览器打开 <http://localhost:18001>，用上面的 Dashboard 密码登录。

在「③ 引擎」里填 LLM / 向量化 API Key，点「保存 Key」→「测试」。

> 只有手机？可以先跳过这步，做完第 3 步拿到 HTTPS 域名后，直接在手机浏览器打开 `https://你的域名` 登录 Dashboard。但第 3 步启动 Tunnel 本身要在 Dashboard 里操作，所以至少需要一次电脑 SSH 转发——或者用命令行方式启动 Tunnel，见第 3 步末尾。

## 3. 拿公网 HTTPS 地址（Cloudflare Tunnel）

Claude.ai 网页版、手机 App 和云端 Claude Code 都需要一个 `https://` 地址。

1. 打开 [Cloudflare Zero Trust](https://one.dash.cloudflare.com) → **Networks → Tunnels → Create a tunnel** → 选 **Cloudflared**，起个名字
2. 在 **Install connector** 页选 **Docker**，复制 `--token` 后面那串（`eyJ` 开头）
3. Dashboard →「设置 → Cloudflare Tunnel」：粘贴 Token →「保存 Token」→「启动」，勾上「启动时自动连接」
4. 状态点变绿后，回 Cloudflare 添加 **Public Hostname**：域名如 `ombre.example.com`，Service Type `HTTP`，URL `localhost:8000`
5. 打开 Dashboard 的 `/onboarding`，选「公网安全模式」，把 `https://ombre.example.com` 填进「公网连接地址」保存，然后重启一次：

   ```bash
   cd /opt/ombre-brain && sudo docker compose restart
   ```

**纯命令行启动 Tunnel（不打开 Dashboard）**：在服务器上运行

```bash
sudo docker run -d --name cloudflared --restart unless-stopped --network host \
  cloudflare/cloudflared:latest tunnel --no-autoupdate --protocol http2 run --token eyJ...
```

这种方式下 Public Hostname 的 URL 要填 `localhost:18001`（走宿主机端口），而不是 `localhost:8000`。

没有域名也可以用 nginx / Caddy + 证书反代，配置见官方 README「从源码部署」一节；不要把端口直接改成 `0.0.0.0` 暴露出去。

## 4. 接到 Claude 上

只需要添加一个连接器，地址是 `https://ombre.example.com/mcp`。

- **Claude.ai 网页版 / 手机**：Settings → Connectors → Add custom connector，填上面的地址，弹出授权页时输入 Dashboard 密码（OAuth）
- **Claude Code**：

  ```bash
  claude mcp add ombre-brain --transport http https://ombre.example.com/mcp
  ```

- **只支持固定 Token 的客户端**：请求头带 `Authorization: Bearer <OMBRE_MCP_TOKEN>`

接上以后，[heartbeat skill](../../.claude/skills/heartbeat/SKILL.md) 里「记忆整理」那几项任务就会生效。

## 日常维护

```bash
cd /opt/ombre-brain

# 看日志
sudo docker compose logs -f --tail 100

# 更新到最新版（重跑安装脚本即可，.env 和记忆不会被覆盖）
sudo bash ~/install.sh

# 备份：所有记忆、config.yaml、Tunnel token 都在这个目录
sudo tar czf ombre-backup-$(date +%F).tar.gz -C /opt/ombre-brain buckets .env
```

Dashboard 里也有带 SHA-256 校验的导出 / 导入功能。
