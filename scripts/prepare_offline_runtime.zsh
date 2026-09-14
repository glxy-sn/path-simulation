#!/bin/zsh
# Siapkan runtime Python portabel di dist/python.
# Beda dengan .venv-runtime: venv menumpang Python milik Homebrew, jadi tidak bisa
# ikut dikemas. Yang ini berdiri sendiri dan aman disalin ke dalam .app.
#
# Cukup dijalankan sekali (atau saat requirements.txt berubah).

set -euo pipefail

UI_ROOT=${0:A:h:h}
WORKSPACE=${UI_ROOT:h}
DIST="$WORKSPACE/dist"
RUNTIME="$DIST/python"
REQ="$WORKSPACE/be/path-simulation/requirements.txt"

PY_RELEASE=20260814
PY_VERSION=3.12.14
TARBALL="cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/${TARBALL//+/%2B}"

info() { print -P "%F{cyan}==>%f $1" }
fail() { print -P "%F{red}GAGAL:%f $1" >&2; exit 1 }

[[ $(uname -m) == arm64 ]] || fail "Skrip ini untuk Mac Apple Silicon. Mac ini: $(uname -m)"
[[ -f "$REQ" ]] || fail "requirements.txt tidak ketemu di $REQ"

mkdir -p "$DIST"

info "Mengunduh CPython portabel ${PY_VERSION}…"
curl -fL --retry 3 -o "$DIST/cpython.tar.gz" "$URL" || fail "unduhan gagal (cek jaringan)"

info "Membongkar…"
rm -rf "$RUNTIME"
tar xzf "$DIST/cpython.tar.gz" -C "$DIST"
[[ -x "$RUNTIME/bin/python3" ]] || fail "hasil bongkar tidak berisi bin/python3"

info "Memasang dependensi backend…"
"$RUNTIME/bin/python3" -m pip install --upgrade pip
"$RUNTIME/bin/python3" -m pip install -r "$REQ"

# Samakan dengan versi yang dipakai .venv-runtime agar hasil analisis tidak bergeser.
"$RUNTIME/bin/python3" -m pip install "ultralytics==8.4.118" "llama-cpp-python==0.3.34"

SITE="$RUNTIME/lib/python3.12/site-packages"

# Sisa kompilasi llama-cpp-python: menaut ke openssl milik Homebrew dan tidak
# pernah dimuat saat runtime (yang dipakai ada di llama_cpp/lib).
info "Membuang sisa build yang menaut ke Homebrew…"
rm -rf "$SITE/lib"

# PyQt5 terseret masuk lewat boxmot tetapi tidak dipakai jalur kode kita (±136 MB).
info "Membuang PyQt5 yang tidak terpakai…"
rm -rf "$SITE"/PyQt5 "$SITE"/PyQt5-*.dist-info "$SITE"/pyqt5_*.dist-info

info "Memeriksa sisa tautan ke Homebrew…"
leftovers=$(find "$RUNTIME" \( -name '*.so' -o -name '*.dylib' \) -exec otool -L {} \; 2>/dev/null \
  | grep -E '/opt/homebrew|/usr/local/(lib|opt)' || true)
if [[ -n "$leftovers" ]]; then
  print -P "%F{yellow}PERINGATAN:%f masih ada tautan ke Homebrew:"
  print "$leftovers"
else
  info "Bersih — runtime tidak bergantung pada Homebrew."
fi

info "Selesai: $RUNTIME"
du -sh "$RUNTIME"
