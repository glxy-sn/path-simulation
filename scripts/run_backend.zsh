#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
PYTHON_BIN="$BACKEND_ROOT/.venv-runtime/bin/python"

if [[ ! -x "$PYTHON_BIN" ]]; then
  print -u2 "Runtime belum tersedia. Jalankan: $BACKEND_ROOT/scripts/setup_runtime.zsh"
  exit 1
fi

RUNTIME_CACHE=${TMPDIR:-/tmp}/foodcourt-runtime-cache
mkdir -p "$RUNTIME_CACHE/matplotlib" "$RUNTIME_CACHE/ultralytics"
export MPLBACKEND=Agg
export MPLCONFIGDIR="$RUNTIME_CACHE/matplotlib"
export YOLO_CONFIG_DIR="$RUNTIME_CACHE/ultralytics"
export PYTHONUNBUFFERED=1
exec "$PYTHON_BIN" "$BACKEND_ROOT/server.py"
