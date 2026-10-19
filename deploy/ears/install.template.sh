#!/usr/bin/env bash
# Lumi 的耳朵（ears-mcp）一键部署 —— 跟 Ombre Brain、语音条部署在同一台 VPS 上
#
# 单文件、自包含：服务端代码内嵌在脚本里，不需要访问 GitHub。
# 由 build.sh 从 install.template.sh + ears_mcp.py 生成 install.sh，别直接改 install.sh。
#
# 用法：sudo bash install.sh            安装 / 更新
#       sudo bash install.sh --warm     预先下载 Whisper 模型（安装时会自动做一次）
#
# 可选环境变量：
#   EARS_DIR        安装目录，默认 /opt/ears
#   EARS_DOMAIN     公网域名，默认 ears.gpt1126.top
#   EARS_PORT       宿主机端口，默认 18003（只绑 127.0.0.1）
#   WHISPER_MODEL   转写模型，默认 small（base 更快更省内存、small 中文准得多、medium 要 2GB+ 内存）
#   CF_DIR          cloudflared 凭据目录，默认 /opt/ombre-brain/cloudflared（存在就自动把域名加进隧道）
#
# 重复运行是安全的：已有的 .env、授权状态、语音和模型缓存不会被覆盖。
set -euo pipefail

EARS_DIR="${EARS_DIR:-/opt/ears}"
EARS_DOMAIN="${EARS_DOMAIN:-ears.gpt1126.top}"
EARS_PORT="${EARS_PORT:-18003}"
WHISPER_MODEL="${WHISPER_MODEL:-small}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 预先加载 Whisper 模型（第一次会经镜像下载权重，small 约 480MB）
warm() {
  log "下载 / 加载 Whisper 模型（第一次要几分钟，取决于网速）"
  $SUDO docker exec ears python -I -c \
    "import sys; sys.path.insert(0,'/app'); import ears_mcp as e; e.get_model(); print('OK: 模型就绪')"
}
if [ "${1:-}" = "--warm" ]; then warm; exit 0; fi

command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1 \
  || die "没找到 docker compose。先跑 Ombre Brain 的 install.sh（它会装好 Docker），再跑这个。"

# 国内服务器：apt / pip / Hugging Face 都走镜像
APT_MIRROR=""
PIP_INDEX="https://pypi.org/simple"
HF_ENDPOINT=""
if ! curl -fsS -m 3 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
  APT_MIRROR="https://mirrors.cloud.tencent.com"
  PIP_INDEX="https://mirrors.cloud.tencent.com/pypi/simple"
fi
if ! curl -fsS -m 3 -o /dev/null https://huggingface.co 2>/dev/null; then
  HF_ENDPOINT="https://hf-mirror.com"
fi

log "安装目录：$EARS_DIR"
$SUDO mkdir -p "$EARS_DIR/data" "$EARS_DIR/models"

# 1. 服务端代码
$SUDO tee "$EARS_DIR/ears_mcp.py" >/dev/null <<'EARS_PY_EOF'
@@EARS_MCP_PY@@
EARS_PY_EOF

# 2. Dockerfile + compose
$SUDO tee "$EARS_DIR/Dockerfile" >/dev/null <<DOCKERFILE
FROM python:3.12-slim
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s#http://deb.debian.org#$APT_MIRROR#g" /etc/apt/sources.list.d/debian.sources 2>/dev/null \\
      || sed -i "s#http://deb.debian.org#$APT_MIRROR#g" /etc/apt/sources.list; fi \\
 && apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-noto-cjk \\
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -i $PIP_INDEX "mcp>=1.9.0,<2" uvicorn python-multipart \\
    "librosa>=0.10" matplotlib numpy "faster-whisper>=1.0"
WORKDIR /app
COPY ears_mcp.py /app/ears_mcp.py
ENV HF_HUB_DISABLE_XET=1 EARS_DATA_DIR=/app/data WHISPER_MODEL_DIR=/app/models MPLCONFIGDIR=/tmp/mpl NUMBA_CACHE_DIR=/app/models/numba \\
    MCP_HOST=0.0.0.0 MCP_PORT=8000 PYTHONUNBUFFERED=1
CMD ["python", "-I", "/app/ears_mcp.py"]
DOCKERFILE

$SUDO tee "$EARS_DIR/docker-compose.yml" >/dev/null <<'YML'
services:
  ears:
    build: .
    image: ears:local
    container_name: ears
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${EARS_PORT:-18003}:8000"
    volumes:
      - ./data:/app/data
      - ./models:/app/models
YML

# 3. .env（只在第一次生成）
ENV_FILE="$EARS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机密码和静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# Lumi 的耳朵 —— 含密码，不要提交到 git、不要截图外传
EARS_PORT=$EARS_PORT
PUBLIC_URL=https://$EARS_DOMAIN
# 录音页登录 + claude.ai 添加连接器时授权，都用这个密码
OAUTH_PASSWORD=$(rand 20)
# 给能填请求头的客户端用：Authorization: Bearer <MCP_AUTH_TOKEN>
MCP_AUTH_TOKEN=$(rand 40)
# 转写：base 快、small 中文准（默认）、medium 更准但要 2GB+ 内存
WHISPER_MODEL=$WHISPER_MODEL
WHISPER_LANGUAGE=zh
# 国内服务器下载模型走 hf-mirror
${HF_ENDPOINT:+HF_ENDPOINT=$HF_ENDPOINT}
# 语音保留天数、单个文件上限、最长分析秒数
CLIP_KEEP_DAYS=30
MAX_UPLOAD_MB=25
MAX_SECONDS=600
EARS_SPEAKER=Timiya
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 构建并启动
log "构建镜像并启动（第一次要下载 Python 镜像、ffmpeg、中文字体和 Whisper 依赖，约 5–10 分钟）"
cd "$EARS_DIR"
$SUDO docker compose up -d --build

log "等待服务就绪（http://127.0.0.1:$EARS_PORT/healthz）"
ok=""
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$EARS_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { $SUDO docker compose logs --tail 40; die "服务没起来，上面是日志"; }
log "耳朵服务已启动 ✅"

warm || log "（模型下载失败也没关系：第一条语音来的时候会再试；可以稍后跑 sudo bash $0 --warm）"

# 5. 把域名加进 Ombre Brain 那条 Cloudflare 隧道（只增不删，不动已有的域名）
if [ -d "$CF_DIR" ] && [ -f "$CF_DIR/cert.pem" ]; then
  TID="$($SUDO ls "$CF_DIR" | grep -E '^[0-9a-f-]{36}\.json$' | head -1 | sed 's/\.json$//')"
  if [ -n "$TID" ]; then
    log "把 $EARS_DOMAIN 加进隧道 $TID"
    CF="$SUDO docker run --rm -v $CF_DIR:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"
    $CF tunnel route dns "$TID" "$EARS_DOMAIN" || log "（DNS 记录可能已存在，继续）"
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
    if ! $SUDO grep -q "hostname: $EARS_DOMAIN\$" "$CFG"; then
      $SUDO awk -v h="$EARS_DOMAIN" -v p="$EARS_PORT" \
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
  fi
else
  log "没找到 $CF_DIR/cert.pem，跳过隧道配置（需要自己把 $EARS_DOMAIN 指到 127.0.0.1:$EARS_PORT）"
fi

echo
echo "录音页：https://$EARS_DOMAIN （手机浏览器打开，输一次密码）"
echo "连接器地址：https://$EARS_DOMAIN/mcp"
echo "密码（录音页和连接器授权共用，看完别截图）：sudo grep OAUTH_PASSWORD $ENV_FILE"
