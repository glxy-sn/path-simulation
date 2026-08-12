#!/bin/bash
# Nyalakan layanan tanya-jawab.
#
# Sengaja memeriksa syaratnya lebih dulu dan berhenti dengan pesan yang jelas.
# Kegagalan yang paling melelahkan bukan yang berteriak, tapi yang diam: kalau
# Ollama mati, chatbot cuma berputar lalu kosong, dan tidak ada yang tahu kenapa.
set -e

MODEL="${CHATBOT_MODEL:-qwen3:8b}"
AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama belum terpasang."
  echo "  Pasang dari https://ollama.com lalu jalankan lagi."
  exit 1
fi

if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Ollama terpasang tapi belum jalan. Buka Terminal lain, jalankan:"
  echo "  ollama serve"
  exit 1
fi

if ! ollama list 2>/dev/null | grep -q "^${MODEL%%:*}"; then
  echo "Model $MODEL belum diunduh (~5 GB). Jalankan:"
  echo "  ollama pull $MODEL"
  exit 1
fi

exec python3 "$AKAR/chat_server.py"
