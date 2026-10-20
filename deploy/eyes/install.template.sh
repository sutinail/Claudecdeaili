#!/usr/bin/env bash
# Lumi 的眼睛（eyes-mcp，小红书版）一键部署 —— 跟 Ombre Brain、语音条、耳朵部署在同一台 VPS 上
#
# 单文件、自包含：服务端代码内嵌在脚本里，不需要访问 GitHub。
# 由 build.sh 从 install.template.sh + eyes_mcp.py 生成 install.sh，别直接改 install.sh。
#
# 用法：sudo bash install.sh                      安装 / 更新
#       sudo bash install.sh --test '<小红书链接>'  在服务器上试抓一条笔记（看能不能读到、图能不能下）
#
# 可选环境变量：
#   EYES_DIR      安装目录，默认 /opt/eyes
#   EYES_DOMAIN   公网域名，默认 eyes.gpt1126.top
#   EYES_PORT     宿主机端口，默认 18004（只绑 127.0.0.1）
#   CF_DIR        cloudflared 凭据目录，默认 /opt/ombre-brain/cloudflared（存在就自动把域名加进隧道）
#
# 重复运行是安全的：已有的 .env、授权状态、缓存不会被覆盖。
set -euo pipefail

EYES_DIR="${EYES_DIR:-/opt/eyes}"
EYES_DOMAIN="${EYES_DOMAIN:-eyes.gpt1126.top}"
EYES_PORT="${EYES_PORT:-18004}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--test" ]; then
  [ -n "${2:-}" ] || die "用法：sudo bash $0 --test '<小红书链接或分享文字>'"
  shift
  exec $SUDO docker exec eyes python -I /app/eyes_mcp.py --test "$*"
fi

command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1 \
  || die "没找到 docker compose。先跑 Ombre Brain 的 install.sh（它会装好 Docker），再跑这个。"

# 国内服务器：pip 走腾讯云镜像
PIP_INDEX="https://pypi.org/simple"
if ! curl -fsS -m 3 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
  PIP_INDEX="https://mirrors.cloud.tencent.com/pypi/simple"
fi

log "安装目录：$EYES_DIR"
$SUDO mkdir -p "$EYES_DIR/data"

# 1. 服务端代码
$SUDO tee "$EYES_DIR/eyes_mcp.py" >/dev/null <<'EYES_PY_EOF'
@@EYES_MCP_PY@@
EYES_PY_EOF

# 2. Dockerfile + compose（不用装系统包，镜像很小，一两分钟就好）
$SUDO tee "$EYES_DIR/Dockerfile" >/dev/null <<DOCKERFILE
FROM python:3.12-slim
RUN pip install --no-cache-dir -i $PIP_INDEX "mcp>=1.9.0,<2" uvicorn httpx "pillow>=10"
WORKDIR /app
COPY eyes_mcp.py /app/eyes_mcp.py
ENV EYES_DATA_DIR=/app/data MCP_HOST=0.0.0.0 MCP_PORT=8000 PYTHONUNBUFFERED=1
CMD ["python", "-I", "/app/eyes_mcp.py"]
DOCKERFILE

$SUDO tee "$EYES_DIR/docker-compose.yml" >/dev/null <<'YML'
services:
  eyes:
    build: .
    image: eyes:local
    container_name: eyes
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${EYES_PORT:-18004}:8000"
    volumes:
      - ./data:/app/data
YML

# 3. .env（只在第一次生成）
ENV_FILE="$EYES_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机密码和静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# Lumi 的眼睛 —— 含密码，不要提交到 git、不要截图外传
EYES_PORT=$EYES_PORT
PUBLIC_URL=https://$EYES_DOMAIN
# claude.ai 添加连接器时授权用这个密码
OAUTH_PASSWORD=$(rand 20)
# 给能填请求头的客户端用：Authorization: Bearer <MCP_AUTH_TOKEN>
MCP_AUTH_TOKEN=$(rand 40)
# 一次最多给 Lumi 几张图、图的长边缩到多少像素
MAX_IMAGES=9
IMG_MAX_SIDE=1024
# 首屏评论最多几条；同一条笔记多少分钟内不重复抓；缓存保留几天
MAX_COMMENTS=20
NOTE_CACHE_MIN=30
KEEP_DAYS=7
# 被小红书风控（读不到笔记）时，可以把自己浏览器里小红书的 Cookie 贴在这里（可选，一般不用）
XHS_COOKIE=
EYES_SPEAKER=Timiya
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 构建并启动
log "构建镜像并启动（第一次要下载 Python 镜像和依赖，一两分钟）"
cd "$EYES_DIR"
$SUDO docker compose up -d --build

log "等待服务就绪（http://127.0.0.1:$EYES_PORT/healthz）"
ok=""
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:$EYES_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { $SUDO docker compose logs --tail 40; die "服务没起来，上面是日志"; }
log "眼睛服务已启动 ✅"

# 5. 把域名加进 Ombre Brain 那条 Cloudflare 隧道（只增不删，不动已有的域名）
if [ -d "$CF_DIR" ] && $SUDO test -f "$CF_DIR/cert.pem"; then
  TID="$($SUDO ls "$CF_DIR" | grep -E '^[0-9a-f-]{36}\.json$' | head -1 | sed 's/\.json$//')"
  if [ -n "$TID" ]; then
    log "把 $EYES_DOMAIN 加进隧道 $TID"
    CF="$SUDO docker run --rm -v $CF_DIR:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"
    $CF tunnel route dns "$TID" "$EYES_DOMAIN" || log "（DNS 记录可能已存在，继续）"
    CFG="$CF_DIR/config.yml"
    if ! $SUDO test -f "$CFG"; then
      OMBRE_HOST="$(grep -h '^  public_url:' /opt/ombre-brain/buckets/config.yaml 2>/dev/null | sed -E 's#.*https://([^"/]+).*#\1#' | head -1)"
      $SUDO tee "$CFG" >/dev/null <<CFGEOF
tunnel: $TID
credentials-file: /home/nonroot/.cloudflared/$TID.json
ingress:
  - hostname: ${OMBRE_HOST:-ombre.gpt1126.top}
    service: http://localhost:18001
  - service: http_status:404
CFGEOF
    fi
    if ! $SUDO grep -q "hostname: $EYES_DOMAIN\$" "$CFG"; then
      $SUDO awk -v h="$EYES_DOMAIN" -v p="$EYES_PORT" \
        '/^  - service: http_status:404/ && !d {print "  - hostname: " h; print "    service: http://localhost:" p; d=1} {print}' \
        "$CFG" | $SUDO tee "$CFG.new" >/dev/null
      $SUDO mv "$CFG.new" "$CFG"
    fi
    $SUDO chown 65532:65532 "$CFG"
    $SUDO docker rm -f cloudflared >/dev/null 2>&1 || true
    $SUDO docker run -d --name cloudflared --restart unless-stopped --network host \
      -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest \
      tunnel --no-autoupdate --protocol http2 --config /home/nonroot/.cloudflared/config.yml run "$TID" >/dev/null
    log "隧道现在转发：$($SUDO grep -h 'hostname:' "$CFG" | awk '{print $3}' | paste -sd' ')"
    echo "   （DNS 记录的目标是：$TID.cfargotunnel.com —— 网页打不开时去 Cloudflare 手动建 CNAME 用）"
  fi
else
  log "没找到 $CF_DIR/cert.pem，跳过隧道配置（需要自己把 $EYES_DOMAIN 指到 127.0.0.1:$EYES_PORT）"
fi

echo
echo "健康检查：https://$EYES_DOMAIN/healthz"
echo "连接器地址：https://$EYES_DOMAIN/mcp"
echo "试抓一条：sudo bash $0 --test '<小红书链接>'"
echo "密码（连接器授权用，看完别截图）：sudo grep OAUTH_PASSWORD $ENV_FILE"
