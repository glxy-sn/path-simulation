#!/bin/zsh
# Rakit Foodcourt.app versi ramping (belasan MB): kode Swift + kode backend saja.
# Runtime Python dan bobot model diunduh sendiri oleh aplikasi saat pertama dibuka.
#
# Pakai: scripts/build_slim_app.zsh <URL-manifest>
# Contoh: scripts/build_slim_app.zsh https://huggingface.co/<akun>/foodcourt-assets/resolve/main/manifest.json

set -euo pipefail

MANIFEST_URL=${1:-}
[[ -n "$MANIFEST_URL" ]] || { print -P "%F{red}GAGAL:%f sebutkan URL manifest sebagai argumen pertama." >&2; exit 1 }

UI_ROOT=${0:A:h:h}
WORKSPACE=${UI_ROOT:h}
BACKEND="$WORKSPACE/backend-shafa"
OUT="$WORKSPACE/dist/Foodcourt.app"
DERIVED="$WORKSPACE/dist/DerivedDataSlim"

info() { print -P "%F{cyan}==>%f $1" }
fail() { print -P "%F{red}GAGAL:%f $1" >&2; exit 1 }

[[ -f "$BACKEND/server.py" ]] || fail "Backend tidak ketemu di $BACKEND"
mkdir -p "$WORKSPACE/dist"

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

# OSNet cuma 2,9 MB, jadi lebih murah ikut di dalam .app daripada dihosting dan
# diunduh — satu berkas lebih sedikit yang bisa gagal saat penyiapan pertama.
info "Menyalin bobot ReID (2,9 MB)…"
mkdir -p "$RES/backend/models"
[[ -f "$BACKEND/osnet_x0_25_msmt17.pt" ]] || fail "osnet_x0_25_msmt17.pt tidak ada di $BACKEND"
cp "$BACKEND/osnet_x0_25_msmt17.pt" "$RES/backend/models/osnet_x0_25_msmt17.pt"

# Alamat manifest ditanam di Info.plist supaya aplikasi tahu harus mengunduh dari mana.
info "Menanam URL manifest…"
/usr/libexec/PlistBuddy -c "Delete :FoodcourtAssetManifestURL" "$OUT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :FoodcourtAssetManifestURL string $MANIFEST_URL" "$OUT/Contents/Info.plist"

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
