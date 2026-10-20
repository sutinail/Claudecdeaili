#!/usr/bin/env bash
# 把 eyes_mcp.py 内嵌进 install.template.sh，生成单文件的 install.sh
set -euo pipefail
cd "$(dirname "$0")"
python3 -I - <<'PY'
tpl = open("install.template.sh").read()
code = open("eyes_mcp.py").read().rstrip("\n")
assert "EYES_PY_EOF" not in code
open("install.sh", "w").write(tpl.replace("@@EYES_MCP_PY@@", code, 1))
PY
chmod +x install.sh
bash -n install.sh
echo "install.sh 已生成"
