#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
RUNTIME_PATH="$BACKEND_ROOT/.venv-runtime"
PYTHON_BIN=${FOODCOURT_PYTHON_BIN:-/opt/homebrew/opt/python@3.12/bin/python3.12}

if [[ ! -x "$PYTHON_BIN" ]]; then
  print -u2 "Python 3.12 tidak ditemukan di $PYTHON_BIN"
  print -u2 "Install dengan: brew install python@3.12"
  exit 1
fi

if [[ ! -d "$RUNTIME_PATH" ]]; then
  "$PYTHON_BIN" -m venv "$RUNTIME_PATH"
fi

"$RUNTIME_PATH/bin/python" -m pip install --upgrade pip wheel
export CMAKE_ARGS="-DGGML_METAL=on"
"$RUNTIME_PATH/bin/python" -m pip install -r "$BACKEND_ROOT/requirements.txt"

"$RUNTIME_PATH/bin/python" - <<'PY'
import fastapi, cv2, torch, shapely, skimage, matplotlib, PIL, huggingface_hub, llama_cpp
print("Foodcourt runtime siap.")
PY

print "Jalankan backend: $BACKEND_ROOT/scripts/run_backend.zsh"
