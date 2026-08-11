#!/bin/bash
# Jalankan engine dengan setelan yang sudah ditetapkan.
#
# Tiga hal di bawah ini pernah salah dan tidak terlihat salah, jadi ditulis di
# sini sekali supaya tidak perlu diingat tiap kali:
#
#   1. yolo11s @1280, bukan bawaan repo (yolo11x @1920). Di Mac ini 11x makan
#      13 menit, 11s dua menit, dan selisih hasilnya satu orang dari 41.
#   2. Kalibrasi diambil dari profil Tiara, MENANG atas titik yang tersimpan di
#      sesi aplikasi. Tanpa ini, analisis diproses dengan kalibrasi lama yang
#      kebetulan masih tersimpan — tanpa satu pun tanda di layar.
#   3. venv_boxmot dipakai, bukan python sistem: server sendiri pustaka standar
#      saja, tapi pipeline butuh torch dan ultralytics.
set -e

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="/Users/fitrimaharani/APPLE INSTITUTE/challenge2/venv_boxmot/bin/python"
PROFIL="${CROWDFLOW_PROFIL_KALIBRASI:-$HOME/Downloads/calibrate-tiara.foodcourtcalibration/profile.json}"

if [ ! -f "$PROFIL" ]; then
  echo "PERINGATAN: profil kalibrasi tidak ada di $PROFIL"
  echo "            analisis akan memakai titik dari sesi aplikasi."
fi

export CROWDFLOW_PYTHON="$VENV"
export CROWDFLOW_PROFIL_KALIBRASI="$PROFIL"
export PRISM_YOLO="${PRISM_YOLO:-yolo11s.pt}"
export PRISM_IMGSZ="${PRISM_IMGSZ:-1280}"

echo "engine  : $PRISM_YOLO @ $PRISM_IMGSZ"
echo "kalibrasi: $PROFIL"
exec "$VENV" "$AKAR/engine/server/server.py"
