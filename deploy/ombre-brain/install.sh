#!/usr/bin/env bash
# Ombre Brain 一键部署（自有 VPS，Docker）
#
# 单文件、自包含：compose 配置内嵌在脚本里，不需要访问 GitHub。
# 适配国内服务器（腾讯云等）：Docker 走系统 apt 源 / 腾讯云镜像，
# 镜像拉取走 Docker Hub 加速，模型默认用硅基流动（国内可直连）。
#
# 用法（在 VPS 上，root 或有 sudo 权限的用户）：
#   bash install.sh
#
# 可选环境变量：
#   OMBRE_DIR               安装目录，默认 /opt/ombre-brain
#   OMBRE_CN                1=按国内网络配置，0=海外；默认自动判断
#   OMBRE_COMPRESS_API_KEY  脱水/打标 LLM 的 key（不填也能启动，之后在 Dashboard 里填）
#   OMBRE_EMBED_API_KEY     向量化的 key（国内默认硅基流动，可和上面同一个）
#   OMBRE_HOST_PORT         宿主机端口，默认 18001（只绑 127.0.0.1）
#
# 重复运行是安全的：已有的 .env 和记忆数据不会被覆盖，只会拉取最新镜像并重启。
set -euo pipefail

OMBRE_DIR="${OMBRE_DIR:-/opt/ombre-brain}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 0. 国内还是海外：Docker Hub 三秒内连不上就当国内
if [ -z "${OMBRE_CN:-}" ]; then
  if curl -fsS -m 3 -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null \
     || [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null)" = "401" ]; then
    OMBRE_CN=0
  else
    OMBRE_CN=1
  fi
fi
[ "$OMBRE_CN" = "1" ] && log "按国内网络配置" || log "按海外网络配置"

# 1. Docker + compose 插件
install_docker_cn() {
  # 先用系统 apt 源（腾讯云 / 阿里云镜像默认已配好）
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker.io docker-compose-v2 && return 0
  # 老版本 Ubuntu 没有 docker-compose-v2：改用腾讯云的 docker-ce 镜像源
  log "系统源没有 compose 插件，改用腾讯云 docker-ce 镜像源"
  . /etc/os-release
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://mirrors.cloud.tencent.com/docker-ce/linux/$ID/gpg" | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.cloud.tencent.com/docker-ce/linux/$ID $VERSION_CODENAME stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

if ! command -v docker >/dev/null 2>&1 || ! $SUDO docker compose version >/dev/null 2>&1; then
  log "安装 Docker 和 compose 插件"
  if [ "$OMBRE_CN" = "1" ] && command -v apt-get >/dev/null 2>&1; then
    install_docker_cn
  else
    curl -fsSL https://get.docker.com | $SUDO sh
  fi
fi

# 2. 国内：配置 Docker Hub 镜像加速（合并进已有 daemon.json，不覆盖其他设置）
if [ "$OMBRE_CN" = "1" ]; then
  MIRRORS="${OMBRE_REGISTRY_MIRRORS:-https://mirror.ccs.tencentyun.com}"
  $SUDO mkdir -p /etc/docker
  DAEMON_CHANGED="$($SUDO python3 - "$MIRRORS" <<'PY'
import json, os, sys
path = "/etc/docker/daemon.json"
cfg = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        cfg = json.load(f)
mirrors = cfg.setdefault("registry-mirrors", [])
changed = False
for m in sys.argv[1].split(","):
    if m and m not in mirrors:
        mirrors.append(m)
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("updated")
PY
)"
  log "Docker Hub 加速：$MIRRORS"
fi
$SUDO systemctl enable docker >/dev/null 2>&1 || true
if ! $SUDO docker info >/dev/null 2>&1; then
  $SUDO systemctl start docker 2>/dev/null || $SUDO service docker start
elif [ "${DAEMON_CHANGED:-}" = "updated" ]; then
  $SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart
fi
$SUDO docker compose version >/dev/null 2>&1 || die "docker compose 不可用，请把上面的输出发给我"

# 3. 目录 + compose 文件（基于官方 deploy/docker-compose.user.yml）
log "安装目录：$OMBRE_DIR"
$SUDO mkdir -p "$OMBRE_DIR/buckets"
$SUDO tee "$OMBRE_DIR/docker-compose.yml" >/dev/null <<'YML'
# 由 install.sh 生成，基于 P0luz/Ombre-Brain 官方 deploy/docker-compose.user.yml
services:
  ombre-brain:
    image: p0luz/ombre-brain:latest
    container_name: ombre-brain
    restart: unless-stopped
    ports:
      - "${OMBRE_BIND_ADDRESS:-127.0.0.1}:${OMBRE_HOST_PORT:-18001}:8000"
    environment:
      - OMBRE_TRANSPORT=streamable-http
      - OMBRE_BIND_ADDRESS=${OMBRE_BIND_ADDRESS:-127.0.0.1}
      - OMBRE_ALLOW_INSECURE_MCP=${OMBRE_ALLOW_INSECURE_MCP:-false}
      - OMBRE_MCP_AUTH_MODE=${OMBRE_MCP_AUTH_MODE:-}
      - OMBRE_MCP_TOKEN=${OMBRE_MCP_TOKEN:-}
      - OMBRE_CONFIG_PATH=/app/buckets/config.yaml
      - OMBRE_COMPRESS_API_KEY=${OMBRE_COMPRESS_API_KEY:-}
      - OMBRE_COMPRESS_BASE_URL=${OMBRE_COMPRESS_BASE_URL:-}
      - OMBRE_COMPRESS_MODEL=${OMBRE_COMPRESS_MODEL:-}
      - OMBRE_COMPRESS_FORMAT=${OMBRE_COMPRESS_FORMAT:-}
      - OMBRE_EMBED_API_KEY=${OMBRE_EMBED_API_KEY:-}
      - OMBRE_EMBED_BASE_URL=${OMBRE_EMBED_BASE_URL:-}
      - OMBRE_EMBED_MODEL=${OMBRE_EMBED_MODEL:-}
      - OMBRE_EMBED_FORMAT=${OMBRE_EMBED_FORMAT:-}
      - OMBRE_DASHBOARD_PASSWORD=${OMBRE_DASHBOARD_PASSWORD:?OMBRE_DASHBOARD_PASSWORD is required}
      - "OMBRE_TRUSTED_PROXY_CIDRS=${OMBRE_TRUSTED_PROXY_CIDRS:-127.0.0.0/8,::1/128}"
      - OMBRE_HOST_VAULT_DIR=${OMBRE_HOST_VAULT_DIR:-}
      - TUNNEL_EDGE=${TUNNEL_EDGE-region1.v2.argotunnel.com:7844,region2.v2.argotunnel.com:7844}
      - TUNNEL_TRANSPORT_PROTOCOL=${TUNNEL_TRANSPORT_PROTOCOL:-http2}
    volumes:
      - type: bind
        source: ${OMBRE_HOST_VAULT_DIR:-./buckets}
        target: /app/buckets
YML

# 4. .env（只在第一次生成）
ENV_FILE="$OMBRE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机 Dashboard 密码和 MCP 静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  if [ "$OMBRE_CN" = "1" ]; then
    # 国内连不上 Gemini：默认硅基流动（Dashboard「服务商预设」同款），key 去 siliconflow.cn 领
    PROVIDER_ENV="OMBRE_COMPRESS_BASE_URL=https://api.siliconflow.cn/v1
OMBRE_COMPRESS_MODEL=deepseek-ai/DeepSeek-V3
OMBRE_COMPRESS_FORMAT=openai_compat
OMBRE_EMBED_BASE_URL=https://api.siliconflow.cn/v1
OMBRE_EMBED_MODEL=BAAI/bge-m3
OMBRE_EMBED_FORMAT=openai_compat"
  else
    PROVIDER_ENV="OMBRE_COMPRESS_BASE_URL=
OMBRE_COMPRESS_MODEL=
OMBRE_COMPRESS_FORMAT=
OMBRE_EMBED_BASE_URL=
OMBRE_EMBED_MODEL=
OMBRE_EMBED_FORMAT="
  fi
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
OMBRE_EMBED_API_KEY=${OMBRE_EMBED_API_KEY:-${OMBRE_COMPRESS_API_KEY:-}}
$PROVIDER_ENV
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 5. 启动
log "拉取镜像并启动（第一次约 500MB）"
cd "$OMBRE_DIR"
$SUDO docker compose pull
$SUDO docker compose up -d

# 6. 健康检查
PORT="$($SUDO grep -E '^OMBRE_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)"
PORT="${PORT:-18001}"
log "等待服务就绪（http://127.0.0.1:$PORT/health）"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    log "Ombre Brain 已启动 ✅"
    echo
    echo "Dashboard 密码和 MCP Token："
    $SUDO grep -E '^OMBRE_(DASHBOARD_PASSWORD|MCP_TOKEN)=' "$ENV_FILE"
    echo "（保存在 $ENV_FILE，别截图外传）"
    echo
    echo "在你自己的电脑上打开 Dashboard（SSH 端口转发）："
    echo "  ssh -L $PORT:127.0.0.1:$PORT <用户>@<服务器IP>"
    echo "  然后浏览器访问 http://localhost:$PORT"
    exit 0
  fi
  sleep 2
done
$SUDO docker compose logs --tail 50
die "两分钟内没等到 /health，上面是最近的日志"
