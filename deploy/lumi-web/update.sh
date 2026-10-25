#!/usr/bin/env bash
# 服务器上一条命令更新前端：拉最新代码 → 重建容器（CLAUDE.md 是单文件挂载，必须重建才看得到新版）→ 看日志
set -euo pipefail
cd "$(dirname "$0")"
git pull --ff-only
sudo docker compose up -d --build --force-recreate
sleep 3
sudo docker logs lumi-web --tail 5
