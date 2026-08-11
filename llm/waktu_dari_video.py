"""Baca stempel waktu yang tercetak di frame CCTV.

Tanpa ini chatbot tahu POLA-nya tapi tidak tahu JAM-nya: "paling ramai di menit
ke-1" benar, tapi tidak menjawab "peak hour jam berapa". Yang hilang cuma satu
angka — kapan rekamannya mulai.

Sumbernya sengaja stempel di gambar, bukan tanggal berkas: tanggal berkas
berubah begitu videonya disalin atau diunduh, sedangkan yang tercetak di frame
adalah waktu menurut kameranya sendiri.

Perlu `tesseract` (brew install tesseract). Kalau tidak ada, fungsi ini
mengembalikan None dan pemanggilnya harus tetap jalan tanpa jam — bukan gagal.

    python3 llm/waktu_dari_video.py <video.mp4> [detik_mulai]
"""
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

# Stempel CCTV hampir selalu di pita paling atas, rata kiri. Dibatasi supaya
# tulisan lain di dalam ruangan (papan, layar) tidak ikut terbaca.
PITA_TINGGI = 0.10
# 45%, bukan 35%: di kamera 2 stempelnya lebih ke kanan, dan potongan 35%
# memotongnya persis di tengah jam — OCR membaca "2026-07-28 11" lalu polanya
# tidak cocok, seolah stempelnya tidak ada.
PITA_LEBAR = 0.45

POLA = re.compile(r"(20\d{2})[-/](\d{2})[-/](\d{2})\D{1,3}(\d{2}):(\d{2}):(\d{2})")


def baca_stempel(video: str, detik: float = 0.0) -> datetime | None:
    """Waktu pada frame di detik ke-`detik`, atau None kalau tidak terbaca."""
    if not shutil.which("tesseract"):
        return None
    try:
        import cv2
    except ImportError:
        return None

    cap = cv2.VideoCapture(str(video))
    cap.set(cv2.CAP_PROP_POS_MSEC, float(detik) * 1000)
    ok, frame = cap.read()
    cap.release()
    if not ok:
        return None

    h, w = frame.shape[:2]
    pita = frame[0:int(h * PITA_TINGGI), 0:int(w * PITA_LEBAR)]
    g = cv2.cvtColor(pita, cv2.COLOR_BGR2GRAY)
    # Diperbesar 3x: stempelnya kecil, dan OCR jauh lebih akurat pada huruf
    # besar.
    g = cv2.resize(g, None, fx=3, fy=3, interpolation=cv2.INTER_CUBIC)

    # BEBERAPA CARA dicoba berurutan. Satu ambang tetap tidak cukup: di kamera
    # yang menghadap jendela, teks putih DAN latarnya sama-sama terang, jadi
    # ambang 200 memutihkan seluruh pita dan stempelnya lenyap. Yang di kamera
    # lain justru paling bersih dengan ambang itu.
    varian = [
        cv2.threshold(g, 200, 255, cv2.THRESH_BINARY)[1],
        cv2.threshold(g, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1],
        cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                              cv2.THRESH_BINARY, 31, -10),
        cv2.threshold(g, 230, 255, cv2.THRESH_BINARY)[1],
        g,                                   # tanpa ambang sama sekali
    ]

    # Mode baca tesseract juga ikut dicoba. "7" (satu baris) paling rapi kalau
    # pitanya bersih; "6" (satu blok) yang justru berhasil waktu di pita itu ada
    # tanaman dan jendela di sebelah stempelnya.
    m = None
    for psm in ("7", "6", "11"):
        for bw in varian:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as t:
                cv2.imwrite(t.name, bw)
                try:
                    keluar = subprocess.run(
                        ["tesseract", t.name, "-", "--psm", psm,
                         "-c", "tessedit_char_whitelist=0123456789-: "],
                        capture_output=True, text=True, timeout=60)
                except subprocess.TimeoutExpired:
                    keluar = None
            Path(t.name).unlink(missing_ok=True)
            if keluar:
                m = POLA.search(keluar.stdout)
                if m:
                    break
        if m:
            break
    if not m:
        return None
    th, bl, hr, ja, me, dt = (int(x) for x in m.groups())
    try:
        return datetime(th, bl, hr, ja, me, dt)
    except ValueError:                       # OCR meleset jadi tanggal mustahil
        return None


def waktu_mulai(video: str, mulai_detik: float) -> datetime | None:
    """Waktu jam dinding saat POTONGAN yang dianalisis dimulai.

    Dibaca pada frame potongan itu sendiri, bukan pada detik 0 lalu ditambah —
    rekaman CCTV sering punya lompatan waktu, dan menambahkan offset ke awal
    berkas akan meleset persis sebesar lompatan itu.
    """
    return baca_stempel(video, mulai_detik)


def jam_pada_menit(mulai: datetime, menit: int) -> str:
    return (mulai + timedelta(minutes=menit)).strftime("%H:%M")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    detik = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    w = baca_stempel(sys.argv[1], detik)
    print(w.strftime("%Y-%m-%d %H:%M:%S") if w else "stempel tidak terbaca")
