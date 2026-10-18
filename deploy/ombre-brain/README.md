# 在自有 VPS 上部署 Ombre Brain

[Ombre Brain](https://github.com/P0luz/Ombre-Brain) 是给 Claude 用的长期记忆系统（MCP 服务）。这里的 `install.sh` 用官方 Docker 镜像把它装到你的 VPS 上，数据存在服务器本地磁盘，重启不丢。

## 0. 准备

- 一台 Linux VPS（1 核 / 1GB 内存起步；要用本地向量模型 bge-m3 需再多 2–3GB 内存）
- 能 SSH 登录，root 或有 sudo 权限
- 可选：一个托管在 Cloudflare 的域名（用来拿 HTTPS 地址给 Claude.ai 连接）
- 可选：LLM API Key，免费方案见官方 README（Google AI Studio / 硅基流动）。不填也能启动，之后在 Dashboard 里填

## 1. 一键安装

SSH 登录 VPS，把 `install.sh` 传上去后运行：

```bash
# 在你自己电脑上（本仓库目录里）
scp deploy/ombre-brain/install.sh <用户>@<服务器IP>:~

# 在 VPS 上
bash ~/install.sh
```

脚本会：

1. 没有 Docker 就自动安装
2. 在 `/opt/ombre-brain` 下载官方 `docker-compose.user.yml`
3. 第一次运行时生成 `/opt/ombre-brain/.env`：随机 Dashboard 密码、随机 MCP 静态 Token，鉴权模式 `hybrid`（OAuth + 静态 Token 共存），端口只绑 `127.0.0.1:18001`
4. 拉镜像、启动、等 `/health` 返回 ok

查看密码和 Token：

```bash
sudo grep -E 'PASSWORD|MCP_TOKEN' /opt/ombre-brain/.env
```

> `.env` 里是万能钥匙，别提交到 git、别截图发出去。

## 2. 打开 Dashboard

服务只监听服务器本机，所以用 SSH 端口转发从你自己电脑访问：

```bash
ssh -L 18001:127.0.0.1:18001 <用户>@<服务器IP>
```

保持这个 SSH 连接，浏览器打开 <http://localhost:18001>，用上面的 Dashboard 密码登录。

在「③ 引擎」里填 LLM / 向量化 API Key，点「保存 Key」→「测试」。

## 3. 拿公网 HTTPS 地址（Cloudflare Tunnel）

Claude.ai 网页版、手机 App 和云端 Claude Code 都需要一个 `https://` 地址。

1. 打开 [Cloudflare Zero Trust](https://one.dash.cloudflare.com) → **Networks → Tunnels → Create a tunnel** → 选 **Cloudflared**，起个名字
2. 在 **Install connector** 页选 **Docker**，复制 `--token` 后面那串（`eyJ` 开头）
3. Dashboard →「设置 → Cloudflare Tunnel」：粘贴 Token →「保存 Token」→「启动」，勾上「启动时自动连接」
4. 状态点变绿后，回 Cloudflare 添加 **Public Hostname**：域名如 `ombre.example.com`，Service Type `HTTP`，URL `localhost:8000`
5. 打开 Dashboard 的 `/onboarding`，选「公网安全模式」，把 `https://ombre.example.com` 填进「公网连接地址」保存，然后重启一次：

   ```bash
   cd /opt/ombre-brain && sudo docker compose -f docker-compose.user.yml restart
   ```

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
sudo docker compose -f docker-compose.user.yml logs -f --tail 100

# 更新到最新版（重跑安装脚本即可，.env 和记忆不会被覆盖）
bash ~/install.sh

# 备份：所有记忆、config.yaml、Tunnel token 都在这个目录
sudo tar czf ombre-backup-$(date +%F).tar.gz -C /opt/ombre-brain buckets .env
```

Dashboard 里也有带 SHA-256 校验的导出 / 导入功能。
