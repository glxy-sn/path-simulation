#!/bin/zsh
# Bikin paket aset yang diunduh aplikasi saat pertama dibuka:
# runtime Python (tar.gz) + empat bobot model, lengkap dengan manifest.json.
#
# Pakai: scripts/package_assets.zsh <URL-dasar>
# <URL-dasar> adalah folder tempat berkas-berkas ini nanti diunggah, tanpa garis miring akhir.

set -euo pipefail

BASE_URL=${1:-}
[[ -n "$BASE_URL" ]] || { print -P "%F{red}GAGAL:%f sebutkan URL dasar sebagai argumen pertama." >&2; exit 1 }
BASE_URL=${BASE_URL%/}

UI_ROOT=${0:A:h:h}
WORKSPACE=${UI_ROOT:h}
RUNTIME="$WORKSPACE/dist/python"
BACKEND="$WORKSPACE/backend-shafa"
OUT="$WORKSPACE/dist/assets"
GGUF="Qwen3-8B-Q4_K_M.gguf"
GGUF_SRC="$HOME/Library/Application Support/Foodcourt/models/$GGUF"

info() { print -P "%F{cyan}==>%f $1" }
fail() { print -P "%F{red}GAGAL:%f $1" >&2; exit 1 }

[[ -x "$RUNTIME/bin/python3" ]] || fail "Runtime Python belum ada di $RUNTIME. Jalankan scripts/prepare_offline_runtime.zsh dulu."
[[ -f "$GGUF_SRC" ]] || fail "$GGUF tidak ada di $GGUF_SRC"

mkdir -p "$OUT"

# Runtime dikemas sebagai tar.gz agar symlink dan bit eksekusi terjaga; keduanya
# wajib, karena python3 di dalamnya sebenarnya symlink ke python3.12.
if [[ -f "$OUT/runtime.tar.gz" ]]; then
  info "runtime.tar.gz sudah ada, dilewati (hapus dulu kalau mau dibuat ulang)."
else
  info "Mengemas runtime Python (lama, ±5 menit)…"
  tar -czf "$OUT/runtime.tar.gz" -C "$(dirname "$RUNTIME")" "$(basename "$RUNTIME")"
fi

# Bobot model TIDAK ikut diunggah: semuanya sudah tersedia di sumber resmi yang
# stabil dan mendukung unduhan lanjut. Yang perlu dihosting sendiri hanya runtime,
# karena llama-cpp-python tidak punya wheel siap pakai untuk macOS arm64 sehingga
# tidak bisa dipasang lewat pip di Mac pengguna.
info "Bobot model diambil dari sumber resmi, tidak perlu diunggah."
[[ -f "$BACKEND/yolo11s.pt" ]] || fail "yolo11s.pt tidak ada di $BACKEND (dipakai untuk checksum)"

# Sumber resmi dipin ke revisi tetap. Kalau hulu mengunggah ulang berkasnya,
# checksum berubah dan aplikasi menolak unduhan itu — pin ini yang mencegahnya.
QWEN_REV="7c41481f57cb95916b40956ab2f0b139b296d974"
URL_QWEN="https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/$QWEN_REV/$GGUF"
URL_YOLOX="https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11x.pt"
URL_YOLOS="https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11s.pt"

info "Menghitung checksum…"
emit() {
  local name=$1 kind=$2 destination=$3 marker=$4 source_file=$5 url=$6
  # JANGAN pakai nama variabel `path`: di zsh ia terikat ke $PATH, dan mengisinya
  # dengan sebuah berkas membuat seluruh perintah eksternal hilang.
  local size=$(command stat -f "%z" "$source_file")
  local digest=$(command shasum -a 256 "$source_file" | command cut -d' ' -f1)
  print "    {\"name\": \"$name\", \"kind\": \"$kind\", \"url\": \"$url\", \"sha256\": \"$digest\", \"size\": $size, \"destination\": \"$destination\", \"marker\": \"$marker\"}"
}

{
  print "{"
  print "  \"version\": \"$(date +%Y%m%d-%H%M)\","
  print "  \"assets\": ["
  entries=(
    "$(emit runtime.tar.gz archive runtime python/bin/python3 "$OUT/runtime.tar.gz" "$BASE_URL/runtime.tar.gz")"
    "$(emit yolo11s.pt file models yolo11s.pt "$BACKEND/yolo11s.pt" "$URL_YOLOS")"
    "$(emit $GGUF file models $GGUF "$GGUF_SRC" "$URL_QWEN")"
  )
  print -l ${(j:,\n:)entries}
  print "  ]"
  print "}"
} > "$OUT/manifest.json"

info "Selesai. Yang perlu diunggah ke $BASE_URL hanya runtime.tar.gz (467 MB):"
ls -lh "$OUT"
print
info "Isi manifest.json:"
cat "$OUT/manifest.json"
