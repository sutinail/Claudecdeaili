#!/usr/bin/env bash
# Lumi 自建前端 · 一键安装
# 在服务器上：sudo bash /opt/claudecdeaili/deploy/lumi-web/install.sh
# 重复运行是安全的：.env 里已经有的值不会被覆盖。
set -euo pipefail
cd "$(dirname "$0")"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'
info() { echo -e "${C}[信息]${NC} $*"; }
ok()   { echo -e "${G}[完成]${NC} $*"; }
warn() { echo -e "${Y}[注意]${NC} $*"; }
fail() { echo -e "${R}[失败]${NC} $*"; exit 1; }

LUMI_HOST="${LUMI_HOST:-chat.gpt1126.top}"
CF_DIR=/opt/ombre-brain/cloudflared
OMBRE_ENV=/opt/ombre-brain/.env
PULSE_ENV=../pulse/.env

command -v docker >/dev/null || fail "没有 Docker。先按 deploy/ombre-brain 的步骤装好"
[[ -f ../../CLAUDE.md ]] || fail "没找到仓库根目录的 CLAUDE.md，要在仓库里的 deploy/lumi-web 下运行"

getv() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
setv() {
  awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k"="v; f=1; next} {print} END{if(!f) print k"="v}' .env > .env.tmp
  mv .env.tmp .env && chmod 600 .env
}
rand() { openssl rand -base64 64 | tr -dc A-Za-z0-9 | head -c "$1"; }

# ── 1. .env ──
[[ -f .env ]] || { cp .env.example .env; chmod 600 .env; info "生成了 .env"; }

NEW_PASS=""
if [[ -z "$(getv LUMI_WEB_PASSWORD .env)" ]]; then NEW_PASS="$(rand 16)"; setv LUMI_WEB_PASSWORD "$NEW_PASS"; fi
[[ -n "$(getv LUMI_WEB_SECRET .env)" ]] || setv LUMI_WEB_SECRET "$(rand 48)"

if [[ -z "$(getv OMBRE_MCP_TOKEN .env)" && -n "$(getv OMBRE_MCP_TOKEN "$OMBRE_ENV")" ]]; then
  setv OMBRE_MCP_TOKEN "$(getv OMBRE_MCP_TOKEN "$OMBRE_ENV")"; ok "从 Ombre Brain 抄来了 MCP Token"
fi
for k in PULSE_MCP_KEY PULSE_SECRET; do
  if [[ -z "$(getv $k .env)" && -n "$(getv $k "$PULSE_ENV")" ]]; then setv "$k" "$(getv $k "$PULSE_ENV")"; ok "从 Pulse 抄来了 $k"; fi
done
[[ -n "$(getv OMBRE_MCP_TOKEN .env)" ]] || warn "没找到 OMBRE_MCP_TOKEN，记忆先不接（之后手动填进 .env 再跑一次本脚本）"
[[ -n "$(getv PULSE_MCP_KEY .env)" ]] || warn "没找到 PULSE_MCP_KEY，身体先不接"

# ── 2. 构建镜像 ──
info "构建镜像（第一次要装 Claude Code，几分钟）..."
if ! timeout 8 curl -fsS https://registry.npmjs.org/ >/dev/null 2>&1; then
  docker compose build
else
  docker compose build --build-arg NPM_REGISTRY=https://registry.npmjs.org
fi
ok "镜像好了"

# ── 3. Claude Code 登录 ──
if [[ -z "$(getv CLAUDE_CODE_OAUTH_TOKEN .env)" ]]; then
  echo
  info "接下来登录 Claude：屏幕上会出现一个网址，复制到浏览器打开 → 登录 Claude 账号 → 授权 → 把页面上的代码粘回这里回车"
  info "成功后它会打印一串 sk-ant-oat01- 开头的 token（别截图）"
  echo
  docker compose run --rm --no-deps lumi-web claude setup-token || warn "setup-token 没跑完，可以重跑本脚本"
  echo
  read -rsp "把上面那串 sk-ant-oat01- 开头的 token 粘贴进来（不会显示，直接回车跳过）: " TOKEN; echo
  TOKEN="$(echo -n "$TOKEN" | tr -d '[:space:]')"
  if [[ -n "$TOKEN" ]]; then setv CLAUDE_CODE_OAUTH_TOKEN "$TOKEN"; ok "token 存进 .env 了"; clear; fi
fi

# ── 4. 语音条 ──
if [[ -z "$(getv ELEVENLABS_API_KEY .env)" ]]; then
  read -rsp "ElevenLabs API Key（不会显示，没有就直接回车跳过）: " XI; echo
  XI="$(echo -n "$XI" | tr -d '[:space:]')"
  [[ -n "$XI" ]] && setv ELEVENLABS_API_KEY "$XI" && ok "语音条 Key 存好了"
fi

# ── 5. 试一下能不能连上 Claude ──
if [[ -n "$(getv CLAUDE_CODE_OAUTH_TOKEN .env)" ]]; then
  info "试着叫醒 Lumi 一次..."
  if OUT="$(timeout 120 docker compose run --rm --no-deps -T lumi-web claude -p "只回一个字：在" --tools "" --model sonnet 2>&1)"; then
    ok "Claude 回话了：$(echo "$OUT" | tail -1)"
  else
    warn "Claude 没连上：$(echo "$OUT" | tail -3)"
    warn "如果是 403 / 地区不支持 / 超时：Anthropic 不对中国大陆服务器开放，要在 .env 里配 HTTPS_PROXY，或者把前端部署到海外服务器（见 README）"
  fi
fi

# ── 6. 启动 ──
docker compose up -d --force-recreate
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8400/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8400/health >/dev/null 2>&1 || fail "前端没起来，看日志：sudo docker logs lumi-web --tail 50"
ok "前端在 127.0.0.1:8400 跑起来了"

# ── 7. Cloudflare 隧道 ──
CFG="$CF_DIR/config.yml"
if [[ -f "$CFG" ]]; then
  if grep -q "hostname: $LUMI_HOST" "$CFG"; then
    ok "隧道里已经有 $LUMI_HOST"
  else
    cp "$CFG" "$CFG.bak.$(date +%s)"
    sed -i "/- service: http_status:404/i\\  - hostname: $LUMI_HOST\\n    service: http://localhost:8400" "$CFG"
    docker run --rm -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest tunnel route dns ombre "$LUMI_HOST" || warn "DNS 路由没加上（已经有同名记录的话可以忽略）"
    docker restart cloudflared >/dev/null && ok "隧道加上 $LUMI_HOST 并重启了"
  fi
else
  warn "没找到 $CFG，隧道要手动配（见 README）"
fi

echo
ok "装好啦 ✅  手机浏览器打开 https://$LUMI_HOST"
if [[ -n "$NEW_PASS" ]]; then
  echo -e "${Y}登录密码（只显示这一次，记下来后运行 clear 清屏，别截图）：${NC} $NEW_PASS"
else
  info "登录密码没变。忘了的话：sudo grep LUMI_WEB_PASSWORD $(pwd)/.env"
fi
