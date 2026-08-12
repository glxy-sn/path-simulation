#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
VENV_PATH="$BACKEND_ROOT/.venv-analysis"
PYTHON_BIN="/opt/homebrew/opt/python@3.12/bin/python3.12"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_FORMULA_BIN="/opt/homebrew/opt/ollama/bin/ollama"
OLLAMA_APP_BIN="/Applications/Ollama.app/Contents/Resources/ollama"

if [[ ! -x "$PYTHON_BIN" ]]; then
  brew install python@3.12
fi

if [[ ! -d "$VENV_PATH" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_PATH"
fi

"$VENV_PATH/bin/python" -m pip install --upgrade pip wheel
"$VENV_PATH/bin/python" -m pip install -r "$BACKEND_ROOT/requirements-analysis.txt"
"$VENV_PATH/bin/python" -m ipykernel install --user --name foodcourt-analysis --display-name "Foodcourt Analysis (Python 3.12)"

if ! brew list --cask ollama-app >/dev/null 2>&1; then
  brew install --cask ollama-app
fi

OLLAMA_BIN="$OLLAMA_APP_BIN"
if ! "$VENV_PATH/bin/python" - "$OLLAMA_APP_BIN" <<'PY'
import subprocess
import sys

try:
    completed = subprocess.run([sys.argv[1], "--version"], timeout=10, capture_output=True)
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit(1)
raise SystemExit(0 if completed.returncode == 0 else 1)
PY
then
  if ! brew list --formula ollama >/dev/null 2>&1; then
    # Keep the requested App installed. Use the formula CLI only when the CLI
    # bundled in the App cannot pass its launch smoke test.
    brew install ollama || true
  fi
  OLLAMA_BIN="$OLLAMA_FORMULA_BIN"
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
  print -u2 "Ollama CLI tidak tersedia setelah instalasi."
  exit 1
fi

if [[ "$OLLAMA_BIN" == "$OLLAMA_FORMULA_BIN" ]] && ! curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  brew services start ollama
  for _ in {1..30}; do
    if curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if [[ "$OLLAMA_BIN" == "$OLLAMA_APP_BIN" ]] && ! curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  open -gj /Applications/Ollama.app || true
  for _ in {1..15}; do
    if curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if ! curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  mkdir -p "$HOME/.ollama/logs"
  OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
    nohup "$OLLAMA_BIN" serve >"$HOME/.ollama/logs/foodcourt-server.log" 2>&1 &
  for _ in {1..60}; do
    if curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

curl --silent --fail "$OLLAMA_URL/api/tags" >/dev/null
if ! "$OLLAMA_BIN" list | awk 'NR > 1 {print $1}' | grep -qx 'qwen3:14b'; then
  "$OLLAMA_BIN" pull qwen3:14b
fi
if ! "$OLLAMA_BIN" list | awk 'NR > 1 {print $1}' | grep -qx 'qwen3-embedding:0.6b'; then
  "$OLLAMA_BIN" pull qwen3-embedding:0.6b
fi

"$VENV_PATH/bin/python" - <<'PY'
import json
from urllib.request import Request, urlopen

base = "http://127.0.0.1:11434"

def post(path, payload, timeout=300):
    req = Request(base + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())

embedding = post("/api/embed", {"model": "qwen3-embedding:0.6b", "input": ["uji retrieval pantry"]})
assert len(embedding.get("embeddings", [])) == 1
chat = post("/api/chat", {
    "model": "qwen3:14b",
    "messages": [{"role": "user", "content": "Pikirkan 2+2, lalu jawab hanya dengan kata siap."}],
    "think": True,
    "stream": False,
    "options": {"num_ctx": 2048, "temperature": 0},
}, timeout=600)
assert (chat.get("message") or {}).get("content")
assert (chat.get("message") or {}).get("thinking"), "Thinking trace tidak diterima dari Qwen3."
print("Health check berhasil: kernel, embedding, chat, dan thinking endpoint siap.")
PY

available_kb=$(df -Pk "$BACKEND_ROOT" | awk 'NR==2 {print $4}')
if (( available_kb < 20971520 )); then
  print -u2 "Peringatan: ruang kosong kurang dari 20 GiB."
fi

print "Setup selesai. Gunakan kernel: Foodcourt Analysis (Python 3.12)"
