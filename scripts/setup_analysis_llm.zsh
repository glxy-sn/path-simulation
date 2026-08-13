#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
VENV_PATH="$BACKEND_ROOT/.venv-analysis"
PYTHON_BIN=${FOODCOURT_PYTHON_BIN:-/opt/homebrew/opt/python@3.12/bin/python3.12}

if [[ ! -x "$PYTHON_BIN" ]]; then
  print -u2 "Python 3.12 tidak ditemukan di $PYTHON_BIN"
  print -u2 "Install dengan: brew install python@3.12"
  exit 1
fi

if [[ ! -d "$VENV_PATH" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_PATH"
fi

"$VENV_PATH/bin/python" -m pip install --upgrade pip wheel
export CMAKE_ARGS="-DGGML_METAL=on"
"$VENV_PATH/bin/python" -m pip install -r "$BACKEND_ROOT/requirements-analysis.txt"
"$VENV_PATH/bin/python" -m ipykernel install --user --name foodcourt-analysis --display-name "Foodcourt Analysis (Python 3.12)"

print "Runtime notebook siap. Qwen3-8B akan diunduh otomatis saat backend atau Tanya Data pertama kali dijalankan."
