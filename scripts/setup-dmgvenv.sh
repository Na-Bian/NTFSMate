#!/bin/bash
# setup-dmgvenv.sh — 创建 DMG .DS_Store 生成所需的 Python venv (ds_store + mac_alias)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m venv "$ROOT/.build/dmgvenv"
"$ROOT/.build/dmgvenv/bin/pip" install --quiet ds_store mac_alias
echo "dmgvenv 就绪: $ROOT/.build/dmgvenv"
