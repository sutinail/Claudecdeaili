#!/usr/bin/env bash
# 服务器上一条命令更新 Pulse：拉最新代码 → 重建容器 → 看日志
set -euo pipefail
cd "$(dirname "$0")"
git pull --ff-only
sudo docker compose up -d --build
sleep 3
sudo docker logs pulse --tail 5
