#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════╗
# ║  脉 · Pulse — 一键安装脚本          ║
# ║  腾讯云 OrcaTerm 里跑一条命令就行    ║
# ╚══════════════════════════════════════╝

INSTALL_DIR="/opt/pulse"
PORT=8300

# ── 颜色 ──
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${C}[信息]${NC} $*"; }
ok()    { echo -e "${G}[完成]${NC} $*"; }
warn()  { echo -e "${Y}[注意]${NC} $*"; }
fail()  { echo -e "${R}[失败]${NC} $*"; exit 1; }

# ── 国内检测 ──
detect_china() {
    if [[ "${PULSE_CN:-}" == "1" ]]; then return 0; fi
    if timeout 5 curl -fsSL https://hub.docker.com >/dev/null 2>&1; then
        return 1
    fi
    info "Docker Hub 连不上，按国内网络处理"
    return 0
}

# ── Docker 安装 ──
ensure_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        ok "Docker 已安装"
        return
    fi

    info "安装 Docker..."
    if detect_china; then
        # 国内：先试 apt，不行用腾讯云镜像源
        if apt-get update -qq && apt-get install -y -qq docker.io docker-compose-plugin 2>/dev/null; then
            ok "Docker 从系统源安装成功"
        else
            info "系统源没有 docker，用腾讯云镜像源..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi

        # 配 Docker Hub 加速
        mkdir -p /etc/docker
        if [[ -f /etc/docker/daemon.json ]]; then
            python3 -c "
import json, sys
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

# ── 安装目录 ──
setup_dir() {
    info "安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # 检查源码是否已经在这里
    if [[ ! -f "$INSTALL_DIR/server/app.py" ]]; then
        # 检查脚本所在目录是否有源码
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$SCRIPT_DIR/server/app.py" ]]; then
            info "从脚本所在目录复制源码..."
            cp -r "$SCRIPT_DIR/server" "$INSTALL_DIR/"
            cp -r "$SCRIPT_DIR/data" "$INSTALL_DIR/"
            [[ -d "$SCRIPT_DIR/firmware" ]] && cp -r "$SCRIPT_DIR/firmware" "$INSTALL_DIR/"
            cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/"
            cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
            cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/"
            [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] && cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"
        else
            # 内嵌生成关键文件
            generate_files
        fi
    else
        info "源码已存在，跳过复制"
    fi
}

# ── 内嵌生成 docker-compose.yml 和 Dockerfile ──
generate_files() {
    warn "没找到源码文件，请先把 deploy/pulse 目录的内容弄到 $INSTALL_DIR"
    warn ""
    warn "方法一（推荐）：在电脑上 scp"
    warn "  scp -r deploy/pulse/* <用户>@<服务器IP>:/opt/pulse/"
    warn ""
    warn "方法二：OrcaTerm 文件上传"
    warn "  把 deploy/pulse 下所有文件传到 /opt/pulse/"
    warn ""
    warn "方法三：仓库临时公开 + git clone"
    warn "  cd /opt && git clone https://github.com/sutinail/Claudecdeaili.git _tmp"
    warn "  cp -r _tmp/deploy/pulse/* /opt/pulse/ && rm -rf _tmp"
    warn "  （完了记得把仓库改回私有）"
    warn ""
    warn "源码就位后重新运行此脚本即可。"
    exit 1
}

# ── 生成 .env ──
setup_env() {
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        info ".env 已存在，保留现有配置"
        return
    fi

    info "生成 .env..."
    SECRET=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 32)

    cat > "$INSTALL_DIR/.env" <<ENVEOF
# 脉 · Pulse 配置（自动生成，不要截图外发）
PULSE_SECRET=$SECRET
PULSE_PORT=$PORT
ENVEOF

    chmod 600 "$INSTALL_DIR/.env"
    ok ".env 已生成"
}

# ── 确保 docker-compose.yml 存在 ──
ensure_compose() {
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        return
    fi

    info "生成 docker-compose.yml..."
    cat > "$INSTALL_DIR/docker-compose.yml" <<'DCEOF'
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
DCEOF
}

# ── 构建启动 ──
build_and_start() {
    cd "$INSTALL_DIR"

    info "构建 Docker 镜像（第一次会慢一点）..."
    if detect_china; then
        # 国内 pip 加速
        if ! grep -q 'mirrors.cloud.tencent.com' Dockerfile 2>/dev/null; then
            # 在 RUN pip install 前加镜像源
            sed -i 's|pip install --no-cache-dir|pip install --no-cache-dir -i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com|' Dockerfile
        fi
    fi

    docker compose build --no-cache
    ok "镜像构建成功"

    info "启动服务..."
    docker compose up -d
    ok "容器已启动"

    # 等待 health
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

    # 显示密钥（提醒不要截图）
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
    echo "  1. 如果要从外网访问（Claude/ESP32），需要 Cloudflare 隧道"
    echo "     跟 Ombre Brain 一样的方法，子域名换成 pulse.gpt1126.top"
    echo ""
    echo "  2. 如果已有 cloudflared 隧道，加一条路由："
    echo "     D=/opt/ombre-brain/cloudflared"
    echo "     sudo docker run --rm -v \$D:/home/nonroot/.cloudflared \\"
    echo "       cloudflare/cloudflared:latest tunnel route dns ombre pulse.gpt1126.top"
    echo "     然后编辑隧道容器加上 pulse 的路由"
    echo ""
    echo "  3. ESP32 大熊固件在 $INSTALL_DIR/firmware/main.py"
    echo "     烧录前改 WiFi 和服务器地址"
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
    setup_dir
    setup_env
    ensure_compose
    build_and_start
    print_result
}

main "$@"
