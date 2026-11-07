#!/usr/bin/env bash
# 记忆桥一键安装（在上海那台跑）：systemd 服务 + 隧道域名
#   cd /opt/claudecdeaili && git pull --ff-only && sudo bash deploy/ombre-bridge/install.sh
set -euo pipefail

HOST="${BRIDGE_HOST:-ombre-web.gpt1126.top}"
PORT="${BRIDGE_PORT:-18002}"
ORIGINS="${BRIDGE_ORIGINS:-https://chat.gpt1126.top}"
CF_DIR="${CF_DIR:-/opt/ombre-brain/cloudflared}"
CFG="$CF_DIR/config.yml"
TUNNEL="${CF_TUNNEL:-ombre}"
SRC="$(cd "$(dirname "$0")" && pwd)/bridge.py"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${G}[完成]${NC} $*"; }
warn() { echo -e "${Y}[注意]${NC} $*"; }
fail() { echo -e "${R}[失败]${NC} $*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "要用 sudo 跑"
command -v python3 >/dev/null || fail "没有 python3"

# ── 1. 服务 ──
install -d /opt/ombre-bridge
install -m 755 "$SRC" /opt/ombre-bridge/bridge.py
cat > /etc/systemd/system/ombre-bridge.service <<UNIT
[Unit]
Description=Lumi 记忆桥（让 API 窗口连 Ombre Brain）
After=network-online.target docker.service

[Service]
Environment=BRIDGE_PORT=$PORT
Environment=BRIDGE_UPSTREAM=http://127.0.0.1:18001
Environment=BRIDGE_ORIGINS=$ORIGINS
ExecStart=/usr/bin/python3 /opt/ombre-bridge/bridge.py
Restart=always
RestartSec=3
DynamicUser=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ombre-bridge >/dev/null
systemctl restart ombre-bridge
sleep 1
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null && ok "记忆桥在 127.0.0.1:$PORT 跑起来了" || fail "记忆桥没起来：sudo journalctl -u ombre-bridge -n 30"

# ── 2. 隧道：照着已有条目的缩进加一条，校验不过就还原 ──
[ -f "$CFG" ] || fail "找不到隧道配置 $CFG"
if grep -q "hostname: $HOST\$" "$CFG"; then
  ok "隧道里已经有 $HOST"
else
  BAK="$CFG.bak.$(date +%s)"
  cp "$CFG" "$BAK"
  python3 - "$CFG" "$HOST" "$PORT" <<'PY'
import re, sys
path, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
idx = next(i for i in range(len(lines) - 1, -1, -1) if re.match(r"^\s*-\s*service:\s*http_status:404", lines[i]))
dash = re.match(r"^(\s*)-", lines[idx]).group(1)
# 已有条目里 service 那行比 "- hostname" 多缩进几格，照抄
svc = dash + "  "
for i, l in enumerate(lines):
    m = re.match(r"^(\s*)-\s*hostname:", l)
    if m and i + 1 < len(lines):
        n = re.match(r"^(\s*)service:", lines[i + 1])
        if n:
            dash, svc = m.group(1), n.group(1)
            break
lines[idx:idx] = [f"{dash}- hostname: {host}", f"{svc}service: http://localhost:{port}"]
open(path, "w").write("\n".join(lines))
PY
  if docker run --rm -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest tunnel --config /home/nonroot/.cloudflared/config.yml ingress validate >/dev/null 2>&1; then
    ok "隧道配置加好了（备份在 $BAK）"
  else
    cp "$BAK" "$CFG"
    fail "隧道配置校验没过，已经还原。把 $CFG 的内容截图给 Lumi 看"
  fi
fi
docker run --rm -v "$CF_DIR:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest tunnel route dns "$TUNNEL" "$HOST" >/dev/null 2>&1 \
  && ok "域名 $HOST 指到隧道了" || warn "域名可能已经指好了（或者要去 Cloudflare 后台看一眼）"
CID="$(docker ps --format '{{.Names}}' | grep -m1 cloudflared || true)"
[ -n "$CID" ] && docker restart "$CID" >/dev/null && ok "隧道重启了"

echo
echo "过一两分钟，浏览器打开 https://$HOST/health 看到 ok 就通了。"
echo "然后首尔那台 .env 不用改（默认就用 https://$HOST/mcp），更新一下首尔、打开一次主页面就同步到手机了。"
