#!/usr/bin/env bash
# Ombre Brain 一键部署（自有 VPS，Docker）
#
# 用法（在 VPS 上，root 或有 sudo 权限的用户）：
#   bash install.sh
#
# 可选环境变量：
#   OMBRE_DIR               安装目录，默认 /opt/ombre-brain
#   OMBRE_COMPRESS_API_KEY  脱水/打标 LLM 的 key（不填也能启动，之后在 Dashboard 里填）
#   OMBRE_HOST_PORT         宿主机端口，默认 18001（只绑 127.0.0.1）
#
# 重复运行是安全的：已有的 .env 和记忆数据不会被覆盖，只会拉取最新镜像并重启。
set -euo pipefail

OMBRE_DIR="${OMBRE_DIR:-/opt/ombre-brain}"
COMPOSE_URL="https://raw.githubusercontent.com/P0luz/Ombre-Brain/main/deploy/docker-compose.user.yml"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 1. Docker
if ! command -v docker >/dev/null 2>&1; then
  log "未检测到 Docker，使用官方脚本安装（get.docker.com）"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
$SUDO docker info >/dev/null 2>&1 || $SUDO systemctl enable --now docker
$SUDO docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件，请先安装 docker-compose-plugin"

# 2. 目录 + compose 文件（每次都拉官方最新版）
log "安装目录：$OMBRE_DIR"
$SUDO mkdir -p "$OMBRE_DIR/buckets"
$SUDO curl -fsSL "$COMPOSE_URL" -o "$OMBRE_DIR/docker-compose.user.yml"

# 3. .env（只在第一次生成）
ENV_FILE="$OMBRE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机 Dashboard 密码和 MCP 静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# Ombre Brain 配置 —— 含密钥，不要提交到 git、不要截图外传
OMBRE_DASHBOARD_PASSWORD=$(rand 24)
# OAuth（Claude.ai 网页版 / Claude Code）+ 静态 Token（其他客户端）共存
OMBRE_MCP_AUTH_MODE=hybrid
OMBRE_MCP_TOKEN=$(rand 48)
# 只绑本机回环；公网访问走 Cloudflare Tunnel 或 nginx/Caddy 反代
OMBRE_BIND_ADDRESS=127.0.0.1
OMBRE_HOST_PORT=${OMBRE_HOST_PORT:-18001}
# 记忆、config.yaml、Tunnel token 都存在这里 —— 记得备份这个目录
OMBRE_HOST_VAULT_DIR=$OMBRE_DIR/buckets
# LLM / 向量化 key：可留空，之后在 Dashboard「③ 引擎」里填，立即生效
OMBRE_COMPRESS_API_KEY=${OMBRE_COMPRESS_API_KEY:-}
OMBRE_COMPRESS_BASE_URL=
OMBRE_COMPRESS_MODEL=
OMBRE_EMBED_API_KEY=
OMBRE_EMBED_BASE_URL=
OMBRE_EMBED_MODEL=
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 启动
log "拉取镜像并启动（第一次约 500MB）"
cd "$OMBRE_DIR"
$SUDO docker compose -f docker-compose.user.yml pull
$SUDO docker compose -f docker-compose.user.yml up -d

# 5. 健康检查
PORT="$($SUDO grep -E '^OMBRE_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)"
PORT="${PORT:-18001}"
log "等待服务就绪（http://127.0.0.1:$PORT/health）"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    log "Ombre Brain 已启动 ✅"
    echo
    echo "Dashboard 密码和 MCP Token 在：$ENV_FILE"
    echo "  查看：$SUDO grep -E 'PASSWORD|MCP_TOKEN' $ENV_FILE"
    echo
    echo "在你自己的电脑上打开 Dashboard（SSH 端口转发）："
    echo "  ssh -L $PORT:127.0.0.1:$PORT <用户>@<服务器IP>"
    echo "  然后浏览器访问 http://localhost:$PORT"
    echo
    echo "下一步：在 Dashboard「设置 → Cloudflare Tunnel」里拿公网 HTTPS 地址，见 README.md"
    exit 0
  fi
  sleep 2
done
$SUDO docker compose -f docker-compose.user.yml logs --tail 50
die "两分钟内没等到 /health，上面是最近的日志"
