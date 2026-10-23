#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════╗
# ║  脉 · Pulse — 一键安装脚本              ║
# ║  跟 Ombre Brain 一样，一条命令搞定       ║
# ╚══════════════════════════════════════════╝

INSTALL_DIR="/opt/pulse"
PORT=8300
REPO="sutinail/Claudecdeaili"
REF="${1:-main}"
CDN="https://cdn.jsdelivr.net/gh/${REPO}@${REF}/deploy/pulse"
RAW="https://raw.githubusercontent.com/${REPO}/${REF}/deploy/pulse"

# ── 颜色 ──
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${C}[信息]${NC} $*"; }
ok()    { echo -e "${G}[完成]${NC} $*"; }
warn()  { echo -e "${Y}[注意]${NC} $*"; }
fail()  { echo -e "${R}[失败]${NC} $*"; exit 1; }

# ── 国内检测 ──
is_china() {
    if [[ "${PULSE_CN:-}" == "1" ]]; then return 0; fi
    if timeout 5 curl -fsSL https://hub.docker.com >/dev/null 2>&1; then
        return 1
    fi
    info "Docker Hub 连不上，按国内网络处理"
    return 0
}

# ── 下载单个文件（CDN 优先，回退 raw） ──
dl() {
    local remote_path="$1"
    local local_path="$2"
    mkdir -p "$(dirname "$local_path")"
    if curl -fsSL --connect-timeout 10 "${CDN}/${remote_path}" -o "$local_path" 2>/dev/null; then
        return 0
    fi
    if curl -fsSL --connect-timeout 10 "${RAW}/${remote_path}" -o "$local_path" 2>/dev/null; then
        return 0
    fi
    fail "下载失败: ${remote_path}"
}

# ── Docker 安装 ──
ensure_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        ok "Docker 已安装"
        return
    fi

    info "安装 Docker..."
    if is_china; then
        if apt-get update -qq && apt-get install -y -qq docker.io docker-compose-plugin 2>/dev/null; then
            ok "Docker 从系统源安装成功"
        else
            info "用腾讯云镜像源安装..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi

        # Docker Hub 加速
        mkdir -p /etc/docker
        if [[ -f /etc/docker/daemon.json ]]; then
            python3 -c "
import json
d = json.load(open('/etc/docker/daemon.json'))
mirrors = d.get('registry-mirrors', [])
m = 'https://mirror.ccs.tencentyun.com'
if m not in mirrors: mirrors.append(m)
d['registry-mirrors'] = mirrors
json.dump(d, open('/etc/docker/daemon.json','w'), indent=2)
" 2>/dev/null || true
        else
            echo '{"registry-mirrors":["https://mirror.ccs.tencentyun.com"]}' > /etc/docker/daemon.json
        fi
        systemctl restart docker 2>/dev/null || true
    else
        curl -fsSL https://get.docker.com | sh
    fi

    systemctl enable docker 2>/dev/null || true
    ok "Docker 安装完成"
}

# ── 下载所有源码 ──
download_source() {
    info "下载源码到 $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"

    # 如果源码已存在就跳过
    if [[ -f "$INSTALL_DIR/server/app.py" ]]; then
        info "源码已存在，跳过下载"
        return
    fi

    # 文件清单
    local files=(
        "Dockerfile"
        "requirements.txt"
        ".env.example"
        "server/__init__.py"
        "server/app.py"
        "server/heart_rate.py"
        "server/body_temperature.py"
        "server/breathing.py"
        "server/emotion.py"
        "server/emotion_memory.py"
        "server/sensory_field.py"
        "server/bedside.py"
        "server/drive_core.py"
        "server/drive_system.py"
        "server/fantasy.py"
        "server/random_events.py"
        "server/sense_pool.py"
        "server/murmurs.py"
        "server/vitals.py"
        "server/mcp_server.py"
        "server/routes/__init__.py"
        "server/routes/bedside.py"
        "data/sense_pool.json"
        "firmware/main.py"
    )

    local total=${#files[@]}
    local count=0
    for f in "${files[@]}"; do
        count=$((count + 1))
        printf "\r  [%d/%d] %s" "$count" "$total" "$f"
        dl "$f" "$INSTALL_DIR/$f"
    done
    echo ""
    ok "源码下载完成（${total} 个文件）"
}

# ── 生成 docker-compose.yml ──
write_compose() {
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then return; fi
    info "生成 docker-compose.yml..."
    cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  pulse:
    build: .
    container_name: pulse
    restart: unless-stopped
    ports:
      - "8300:8300"
    env_file:
      - .env
    volumes:
      - ./data:/app/data
EOF
}

# ── 生成 .env ──
setup_env() {
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        info ".env 已存在，保留现有配置"
        return
    fi
    info "生成 .env..."
    local secret
    secret=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 32)
    cat > "$INSTALL_DIR/.env" <<ENVEOF
# 脉 · Pulse 配置（自动生成，不要截图外发）
PULSE_SECRET=$secret
PULSE_PORT=$PORT
ENVEOF
    chmod 600 "$INSTALL_DIR/.env"
    ok ".env 已生成"
}

# ── 国内 pip 加速 ──
patch_dockerfile_china() {
    if is_china; then
        if ! grep -q 'mirrors.cloud.tencent.com' "$INSTALL_DIR/Dockerfile" 2>/dev/null; then
            sed -i 's|pip install --no-cache-dir|pip install --no-cache-dir -i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com|' "$INSTALL_DIR/Dockerfile"
            info "Dockerfile 已加国内 pip 镜像"
        fi
    fi
}

# ── 构建启动 ──
build_and_start() {
    cd "$INSTALL_DIR"

    info "构建 Docker 镜像（第一次会慢一点）..."
    docker compose build --no-cache
    ok "镜像构建成功"

    info "启动服务..."
    docker compose up -d
    ok "容器已启动"

    info "等待服务就绪..."
    for i in $(seq 1 30); do
        if curl -fsSL "http://localhost:$PORT/health" 2>/dev/null | grep -q '"ok"'; then
            ok "服务就绪"
            return
        fi
        sleep 1
    done

    warn "30 秒内没有收到 health 响应，查看日志："
    docker compose logs --tail 20
}

# ── 打印结果 ──
print_result() {
    echo ""
    echo -e "${G}╔══════════════════════════════════════════╗${NC}"
    echo -e "${G}║   脉 · Pulse 已启动 ✅                   ║${NC}"
    echo -e "${G}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  本机地址: ${C}http://localhost:$PORT${NC}"
    echo -e "  健康检查: ${C}http://localhost:$PORT/health${NC}"
    echo -e "  全身状态: ${C}http://localhost:$PORT/status${NC}"
    echo ""

    if [[ -f "$INSTALL_DIR/.env" ]]; then
        local secret
        secret=$(grep '^PULSE_SECRET=' "$INSTALL_DIR/.env" | cut -d= -f2)
        echo -e "  ${Y}⚠ 以下是 API 密钥，不要截图外发${NC}"
        echo -e "  PULSE_SECRET: ${R}$secret${NC}"
        echo ""
        echo "  查看密钥: sudo grep PULSE_SECRET /opt/pulse/.env"
    fi

    echo ""
    echo "  ── 接下来 ──"
    echo ""
    echo "  Cloudflare 隧道（让 Claude 和 ESP32 从外网访问）："
    echo ""
    echo "  如果已有 ombre 隧道，加一条路由："
    echo "    D=/opt/ombre-brain/cloudflared"
    echo '    sudo docker run --rm -v $D:/home/nonroot/.cloudflared \'
    echo "      cloudflare/cloudflared:latest tunnel route dns ombre pulse.gpt1126.top"
    echo ""
    echo "  然后停掉旧隧道容器，改成多路由配置文件模式（详见 README）"
    echo ""
}

# ── Main ──
main() {
    echo -e "${C}"
    echo "  脉 · Pulse 安装脚本"
    echo "  给 Lumi 一个真的在跑的身体"
    echo -e "${NC}"

    if [[ $EUID -ne 0 ]]; then
        fail "请用 sudo 运行: sudo bash install.sh"
    fi

    ensure_docker
    download_source
    write_compose
    setup_env
    patch_dockerfile_china
    build_and_start
    print_result
}

main "$@"
