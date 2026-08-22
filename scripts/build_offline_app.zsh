#!/bin/zsh
# Rakit Foodcourt.app yang berjalan sepenuhnya luring:
# runtime Python portabel, kode backend, dan seluruh bobot model ikut di dalam bundel.
#
# Prasyarat: scripts/prepare_offline_runtime.zsh sudah dijalankan sekali.
# Pakai: scripts/build_offline_app.zsh

set -euo pipefail

UI_ROOT=${0:A:h:h}
WORKSPACE=${UI_ROOT:h}
RUNTIME="$WORKSPACE/dist/python"
BACKEND="$WORKSPACE/backend-shafa"
OUT="$WORKSPACE/dist/Foodcourt.app"
DERIVED="$WORKSPACE/dist/DerivedData"

MODELS=(yolo11x.pt yolo11s.pt osnet_x0_25_msmt17.pt)
GGUF="Qwen3-8B-Q4_K_M.gguf"
GGUF_SRC="$HOME/Library/Application Support/Foodcourt/models/$GGUF"

info() { print -P "%F{cyan}==>%f $1" }
fail() { print -P "%F{red}GAGAL:%f $1" >&2; exit 1 }

[[ -x "$RUNTIME/bin/python3" ]] || fail "Runtime Python belum ada di $RUNTIME. Jalankan scripts/prepare_offline_runtime.zsh dulu."
[[ -f "$BACKEND/server.py" ]] || fail "Backend tidak ketemu di $BACKEND"

# 1. Bangun aplikasi. Sandbox dan hardened runtime dimatikan lewat override,
#    bukan lewat project.pbxproj, supaya setelan tim tidak ikut berubah.
info "Membangun foodcourt (Release)…"
rm -rf "$DERIVED"
xcodebuild \
  -project "$UI_ROOT/foodcourt.xcodeproj" \
  -scheme foodcourt \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ENABLE_APP_SANDBOX=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build > "$WORKSPACE/dist/xcodebuild.log" 2>&1 \
  || { tail -40 "$WORKSPACE/dist/xcodebuild.log"; fail "xcodebuild gagal — log lengkap di dist/xcodebuild.log" }

BUILT=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "foodcourt.app" | head -1)
[[ -n "$BUILT" ]] || fail "foodcourt.app tidak ditemukan di hasil build"

rm -rf "$OUT"
cp -R "$BUILT" "$OUT"
RES="$OUT/Contents/Resources"

# 2. Runtime Python portabel.
info "Menyalin runtime Python (±1.6 GB)…"
rm -rf "$RES/python"
cp -R "$RUNTIME" "$RES/python"

# 3. Kode backend — tanpa venv, hasil analisis, cache, atau berkas kerja.
info "Menyalin kode backend…"
rm -rf "$RES/backend"
mkdir -p "$RES/backend"
rsync -a \
  --exclude '.git' --exclude '.venv*' --exclude '__pycache__' \
  --exclude 'hasil' --exclude 'hasil-*' --exclude 'job*.json' \
  --exclude '*.pt' --exclude '.DS_Store' --exclude 'scripts' \
  "$BACKEND/" "$RES/backend/"

# 4. Seluruh bobot model, supaya runtime tidak pernah menyentuh jaringan.
info "Menyalin bobot model…"
mkdir -p "$RES/backend/models"
for w in $MODELS; do
  [[ -f "$BACKEND/$w" ]] || fail "Bobot $w tidak ada di $BACKEND"
  cp "$BACKEND/$w" "$RES/backend/models/$w"
done

if [[ -f "$GGUF_SRC" ]]; then
  info "Menyalin $GGUF (4.7 GB, sabar)…"
  cp "$GGUF_SRC" "$RES/backend/models/$GGUF"
else
  print -P "%F{yellow}PERINGATAN:%f $GGUF tidak ditemukan — aplikasi jalan, tapi chatbot akan mengunduh saat pertama dipakai."
fi

# 5. Buang cache bytecode sebelum menandatangani. Berkas .pyc yang muncul di
#    dalam bundel setelah penandatanganan akan merusak segel, dan macOS di Mac
#    lain menolaknya dengan pesan menyesatkan "is damaged and can't be opened".
info "Membersihkan __pycache__…"
find "$RES" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
find "$RES" -name '*.pyc' -delete 2>/dev/null

# 6. Tanda tangan ad-hoc supaya macOS mau menjalankannya.
info "Menandatangani ad-hoc…"
codesign --force --deep --sign - "$OUT" 2>/dev/null || \
  print -P "%F{yellow}Catatan:%f codesign --deep mengeluh; aplikasi biasanya tetap jalan lewat klik-kanan → Open."

# 7. Segelnya wajib utuh; kalau tidak, .app ini akan ditolak di Mac orang lain.
info "Memverifikasi segel…"
if codesign --verify --deep "$OUT" 2>/dev/null; then
  info "Segel utuh."
else
  print -P "%F{red}PERINGATAN:%f segel tidak utuh — jangan dibagikan sebelum ini beres:"
  codesign --verify --verbose=2 "$OUT" 2>&1 | head -5
fi

info "Selesai: $OUT"
du -sh "$OUT"
