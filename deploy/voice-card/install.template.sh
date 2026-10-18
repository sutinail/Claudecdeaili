#!/usr/bin/env bash
# 语音条（voice-card-mcp）一键部署 —— 跟 Ombre Brain 部署在同一台 VPS 上
#
# 单文件、自包含：服务端代码内嵌在脚本里，不需要访问 GitHub。
# 由 build.sh 从 install.template.sh + voice_card_mcp.py 生成 install.sh，别直接改 install.sh。
#
# 用法：sudo bash install.sh
#
# 可选环境变量：
#   VOICE_DIR       安装目录，默认 /opt/voice-card
#   VOICE_DOMAIN    公网域名，默认 voice.gpt1126.top
#   VOICE_PORT      宿主机端口，默认 18002（只绑 127.0.0.1）
#   VOICE_ID        ElevenLabs 音色，默认 Lumi（48uZMMvYcyyJiRxqFbxG）
#   CF_DIR          cloudflared 凭据目录，默认 /opt/ombre-brain/cloudflared（存在就自动把域名加进隧道）
#
# 重复运行是安全的：已有的 .env、授权状态和音频不会被覆盖。
set -euo pipefail

VOICE_DIR="${VOICE_DIR:-/opt/voice-card}"
VOICE_DOMAIN="${VOICE_DOMAIN:-voice.gpt1126.top}"
VOICE_PORT="${VOICE_PORT:-18002}"
VOICE_ID="${VOICE_ID:-48uZMMvYcyyJiRxqFbxG}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

# 合成一句话测试 ElevenLabs 是否可用
tts_test() {
  log "合成一句测试语音"
  $SUDO docker exec voice-card python -I -c \
    "import sys; sys.path.insert(0,'/app'); import voice_card_mcp as v; print(v.synthesize('Hey, Timiya. It is Lumi.'))"
}

# sudo bash install.sh --set-key：粘贴 ElevenLabs API Key（不回显、不进 shell 历史），写入 .env 并重启
if [ "${1:-}" = "--set-key" ]; then
  [ -f "$VOICE_DIR/.env" ] || die "还没装，先运行 sudo bash $0"
  printf '粘贴 ElevenLabs API Key 后回车（屏幕上不会显示）：'
  IFS= read -rs KEY; echo
  [ -n "$KEY" ] || die "没读到 Key"
  [ -z "$SUDO" ] || die "请用 sudo bash $0 --set-key 运行"
  KEY="$KEY" awk 'BEGIN{k=ENVIRON["KEY"]} /^ELEVENLABS_API_KEY=/{print "ELEVENLABS_API_KEY=" k; next} {print}' \
    "$VOICE_DIR/.env" > "$VOICE_DIR/.env.new"
  $SUDO chmod 600 "$VOICE_DIR/.env.new" && $SUDO mv "$VOICE_DIR/.env.new" "$VOICE_DIR/.env"
  unset KEY
  cd "$VOICE_DIR" && $SUDO docker compose up -d --force-recreate >/dev/null
  sleep 4
  tts_test
  exit 0
fi
if [ "${1:-}" = "--test" ]; then tts_test; exit 0; fi

command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1 \
  || die "没找到 docker compose。先跑 Ombre Brain 的 install.sh（它会装好 Docker），再跑这个。"

# 国内服务器 pip 走腾讯云镜像
PIP_INDEX="https://pypi.org/simple"
if ! curl -fsS -m 3 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
  PIP_INDEX="https://mirrors.cloud.tencent.com/pypi/simple"
fi

log "安装目录：$VOICE_DIR"
$SUDO mkdir -p "$VOICE_DIR/audio" "$VOICE_DIR/data"

# 1. 服务端代码
$SUDO tee "$VOICE_DIR/voice_card_mcp.py" >/dev/null <<'VOICE_PY_EOF'
@@VOICE_CARD_MCP_PY@@
VOICE_PY_EOF

# 2. Dockerfile + compose
$SUDO tee "$VOICE_DIR/Dockerfile" >/dev/null <<DOCKERFILE
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir -i $PIP_INDEX "mcp>=1.9.0,<2" requests uvicorn
COPY voice_card_mcp.py /app/voice_card_mcp.py
ENV AUDIO_DIR=/app/audio OAUTH_STATE_FILE=/app/data/oauth.json MCP_HOST=0.0.0.0 MCP_PORT=8000 PYTHONUNBUFFERED=1
CMD ["python", "-I", "/app/voice_card_mcp.py"]
DOCKERFILE

$SUDO tee "$VOICE_DIR/docker-compose.yml" >/dev/null <<'YML'
services:
  voice-card:
    build: .
    image: voice-card:local
    container_name: voice-card
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${VOICE_PORT:-18002}:8000"
    volumes:
      - ./audio:/app/audio
      - ./data:/app/data
YML

# 3. .env（只在第一次生成）
ENV_FILE="$VOICE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "生成 .env（随机授权密码和静态 Token）"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  $SUDO tee "$ENV_FILE" >/dev/null <<ENV
# 语音条配置 —— 含密钥，不要提交到 git、不要截图外传
VOICE_PORT=$VOICE_PORT
TTS_PROVIDER=elevenlabs
# 去 ElevenLabs 后台建一个只开 Text to Speech 权限、设了额度上限的 API Key，填在这里
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=$VOICE_ID
ELEVENLABS_MODEL=eleven_multilingual_v2
# 公网地址：OAuth 授权和音频链接都用它
PUBLIC_URL=https://$VOICE_DOMAIN
AUDIO_BASE_URL=https://$VOICE_DOMAIN/audio
AUDIO_KEEP_DAYS=7
# claude.ai 添加连接器时，授权页要输入的密码
OAUTH_PASSWORD=$(rand 20)
# 给能填请求头的客户端用：Authorization: Bearer <MCP_AUTH_TOKEN>
MCP_AUTH_TOKEN=$(rand 40)
ENV
  $SUDO chmod 600 "$ENV_FILE"
else
  log "已存在 .env，保留不动"
fi

# 4. 构建并启动
log "构建镜像并启动（第一次要下载 Python 镜像和依赖，稍等）"
cd "$VOICE_DIR"
$SUDO docker compose up -d --build

log "等待服务就绪（http://127.0.0.1:$VOICE_PORT/healthz）"
ok=""
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$VOICE_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { $SUDO docker compose logs --tail 40; die "服务没起来，上面是日志"; }
log "语音条服务已启动 ✅"

# 5. 把域名加进 Ombre Brain 那条 Cloudflare 隧道
if [ -d "$CF_DIR" ] && [ -f "$CF_DIR/cert.pem" ]; then
  TID="$($SUDO ls "$CF_DIR" | grep -E '^[0-9a-f-]{36}\.json$' | head -1 | sed 's/\.json$//')"
  if [ -n "$TID" ]; then
    log "把 $VOICE_DOMAIN 加进隧道 $TID"
    CF="$SUDO docker run --rm -v $CF_DIR:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"
    $CF tunnel route dns "$TID" "$VOICE_DOMAIN" || log "（DNS 记录可能已存在，继续）"
    OMBRE_HOST="$(grep -h '^  public_url:' /opt/ombre-brain/buckets/config.yaml 2>/dev/null | sed -E 's#.*https://([^"/]+).*#\1#' | head -1)"
    OMBRE_HOST="${OMBRE_HOST:-ombre.gpt1126.top}"
    $SUDO tee "$CF_DIR/config.yml" >/dev/null <<CFG
tunnel: $TID
credentials-file: /home/nonroot/.cloudflared/$TID.json
ingress:
  - hostname: $OMBRE_HOST
    service: http://localhost:18001
  - hostname: $VOICE_DOMAIN
    service: http://localhost:$VOICE_PORT
  - service: http_status:404
CFG
    $SUDO chown 65532:65532 "$CF_DIR/config.yml"
    $SUDO docker rm -f cloudflared >/dev/null 2>&1 || true
    $SUDO docker run -d --name cloudflared --restart unless-stopped --network host \
      -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest \
      tunnel --no-autoupdate --protocol http2 --config /home/nonroot/.cloudflared/config.yml run "$TID" >/dev/null
    log "隧道已改为两个域名：$OMBRE_HOST 和 $VOICE_DOMAIN"
  fi
else
  log "没找到 $CF_DIR/cert.pem，跳过隧道配置（需要自己把 $VOICE_DOMAIN 指到 127.0.0.1:$VOICE_PORT）"
fi

echo
if ! $SUDO grep -qE '^ELEVENLABS_API_KEY=.+' "$ENV_FILE"; then
  echo "下一步：填 ElevenLabs API Key（命令会让你粘贴，屏幕上不显示）："
  echo "  sudo bash $0 --set-key"
fi
echo "授权密码（添加连接器时用，看完别截图）：sudo grep OAUTH_PASSWORD $ENV_FILE"
echo "连接器地址：https://$VOICE_DOMAIN/mcp"
