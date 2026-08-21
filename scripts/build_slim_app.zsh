#!/bin/zsh
# Rakit U See.app versi ramping: kode Swift + kode backend saja.
# Runtime Python dan seluruh bobot model diunduh sendiri oleh aplikasi saat pertama dibuka.
#
# Pakai: scripts/build_slim_app.zsh [URL-manifest]
# Tanpa argumen, gunakan manifest handover U See yang dipublikasikan.

set -euo pipefail

DEFAULT_MANIFEST_URL="https://huggingface.co/fitrim14111/foodcourt-runtime/resolve/main/manifest.json"
MANIFEST_URL=${1:-$DEFAULT_MANIFEST_URL}

UI_ROOT=${0:A:h:h}
WORKSPACE=${UI_ROOT:h}
BACKEND="$WORKSPACE/be/path-simulation"
OUT="$WORKSPACE/dist/U See.app"
DERIVED="$WORKSPACE/dist/DerivedDataSlim"

info() { print -P "%F{cyan}==>%f $1" }
fail() { print -P "%F{red}GAGAL:%f $1" >&2; exit 1 }

[[ -f "$BACKEND/server.py" ]] || fail "Backend tidak ketemu di $BACKEND"
mkdir -p "$WORKSPACE/dist"

info "Membangun U See (Release)…"
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
  build > "$WORKSPACE/dist/xcodebuild-slim.log" 2>&1 \
  || { tail -40 "$WORKSPACE/dist/xcodebuild-slim.log"; fail "xcodebuild gagal — log di dist/xcodebuild-slim.log" }

BUILT=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "foodcourt.app" | head -1)
[[ -n "$BUILT" ]] || fail "foodcourt.app tidak ditemukan di hasil build"

rm -rf "$OUT"
cp -R "$BUILT" "$OUT"
RES="$OUT/Contents/Resources"

# Kode backend ikut karena kecil (beberapa MB) dan sering berubah — dengan begitu
# perbaikan bug Python cukup dikirim ulang sebagai .app belasan MB, bukan 5 GB.
info "Menyalin kode backend…"
rm -rf "$RES/backend"
mkdir -p "$RES/backend"
rsync -a \
  --exclude '.git' --exclude '.venv*' --exclude '__pycache__' \
  --exclude 'hasil' --exclude 'hasil-*' --exclude 'job*.json' \
  --exclude '*.pt' --exclude '.DS_Store' --exclude 'scripts' \
  "$BACKEND/" "$RES/backend/"

# OSNet kecil tetapi wajib untuk ReID dua kamera. Manifest publik saat ini
# menyimpan model besar saja, jadi checkpoint ReID tetap ikut di bundle.
info "Menyalin bobot ReID…"
mkdir -p "$RES/backend/models"
[[ -f "$BACKEND/osnet_x0_25_msmt17.pt" ]] || fail "osnet_x0_25_msmt17.pt tidak ada di $BACKEND"
cp "$BACKEND/osnet_x0_25_msmt17.pt" "$RES/backend/models/osnet_x0_25_msmt17.pt"

# Alamat manifest ditanam di Info.plist supaya aplikasi tahu harus mengunduh
# runtime dan seluruh model ke Application Support pada setup pertama.
info "Menanam URL manifest…"
/usr/libexec/PlistBuddy -c "Delete :USeeAssetManifestURL" "$OUT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :USeeAssetManifestURL string $MANIFEST_URL" "$OUT/Contents/Info.plist"

info "Membersihkan __pycache__…"
find "$RES" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
find "$RES" -name '*.pyc' -delete 2>/dev/null

info "Menandatangani ad-hoc…"
codesign --force --deep --sign - "$OUT" 2>/dev/null || \
  print -P "%F{yellow}Catatan:%f codesign --deep mengeluh."

info "Memverifikasi segel…"
if codesign --verify --deep "$OUT" 2>/dev/null; then
  info "Segel utuh."
else
  print -P "%F{red}PERINGATAN:%f segel tidak utuh — jangan dibagikan:"
  codesign --verify --verbose=2 "$OUT" 2>&1 | head -5
fi

info "Selesai: $OUT"
du -sh "$OUT"
