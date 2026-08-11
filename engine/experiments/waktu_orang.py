"""Hitung WAKTU-ORANG dan porsi DIAM per zona — ukuran yang kebal ID switch.

Kenapa bukan "berapa orang duduk dan berapa lama masing-masing": ukuran itu
bergantung penuh pada identitas, dan identitas adalah bagian paling rapuh dari
pipeline (fusi lintas kamera nyaris tidak bekerja, `totalVisitors` berlebih
~20%). Kalau satu orang pecah jadi tiga ID, dwell per orang ikut terpotong tiga.

Waktu-orang tidak pernah bertanya "siapa". Satu orang duduk 10 menit menyumbang
10 menit-orang, mau ID-nya utuh atau pecah lima kali. Diam-vs-lewat juga hanya
melihat perpindahan antar sampel berdekatan — bagian tracking yang justru paling
andal (IDF1 95,3 di dalam satu kamera).

Hasilnya: per zona, berapa besar pemakaiannya DAN apakah pemakaian itu orang
berlama-lama atau orang lewat. Meja yang ramai karena dilewati dan meja yang
ramai karena ditongkrongi terlihat sama di heatmap; di sini tidak.

    python engine/experiments/waktu_orang.py ~/Documents/crowdflow/run-<id>
"""
import json
import sys
from pathlib import Path

import numpy as np

# Di bawah kecepatan ini orangnya dianggap DIAM. 0,25 m/detik kira-kira
# seperempat kecepatan jalan santai — cukup longgar untuk menampung orang duduk
# yang bergeser di kursinya, cukup ketat untuk memisahkan dari orang berjalan.
AMBANG_DIAM_MS = 0.25


def proyeksi(H, pts):
    p = np.hstack([np.asarray(pts, float), np.ones((len(pts), 1))])
    w = p @ np.asarray(H, float).T
    return w[:, :2] / w[:, 2:3]


def muat_kamera(folder, kalibrasi):
    """Kembalikan (label, jejak_meter, jejak_norm, detik_per_sampel)."""
    d = json.load(open(folder / "hasil.json"))
    label = json.load(open(folder / "kamera.json"))["label"]
    fps = d["sumber"]["fps_sumber"]
    langkah = d.get("jejakLangkah") or 1
    detik_per_sampel = langkah / fps

    cam = next((c for c in kalibrasi["cameras"] if c["label"] == label), None)
    H = W = Hh = None
    if cam:
        H = np.asarray(cam["calibration"]["H_cam_to_world"], float)
        W, Hh = cam["image_size"]["width"], cam["image_size"]["height"]

    jejak = {}
    for tid, pts in d["jejakWaktu"].items():
        norm = np.asarray([[nx, ny] for _, nx, ny in pts], float)
        frame = np.asarray([f for f, _, _ in pts], float)
        meter = proyeksi(H, norm * [W, Hh]) if H is not None else None
        jejak[tid] = (frame, norm, meter)
    return label, jejak, detik_per_sampel, fps, d.get("zones", [])


def dalam_zona(titik_norm, z):
    """Zona disimpan sebagai kotak ternormalisasi (x, y = sudut kiri-atas)."""
    x, y = titik_norm
    return z["x"] <= x < z["x"] + z["w"] and z["y"] <= y < z["y"] + z["h"]


def hitung(folder):
    folder = Path(folder).expanduser()
    kal = next((json.load(open(p)) for p in sorted(folder.rglob("kalibrasi.json"))), None)
    if kal is None:
        sys.exit(f"tidak ada kalibrasi.json di {folder} — jalankan cek_kalibrasi.py dulu")

    for sub in sorted(p for p in folder.iterdir() if (p / "hasil.json").exists()):
        label, jejak, dt, fps, zones = muat_kamera(sub, kal)
        if not zones:
            continue

        # Akumulator per zona: detik-orang total, dan berapa detik di antaranya
        # orangnya diam.
        total = {z["code"]: 0.0 for z in zones}
        diam = {z["code"]: 0.0 for z in zones}
        luar = 0.0

        for frame, norm, meter in jejak.values():
            if len(norm) < 2:
                continue
            # Kecepatan tiap sampel, dari perpindahan ke sampel BERIKUTNYA.
            # Sampel terakhir mewarisi kecepatan sebelumnya — tidak ada
            # sesudahnya untuk dibandingkan.
            if meter is not None:
                jarak = np.hypot(*(meter[1:] - meter[:-1]).T)
                # Jeda dihitung dari NOMOR FRAME, tidak diasumsikan seragam:
                # track yang sempat putus punya lompatan besar antar sampel, dan
                # membaginya dengan jeda tetap akan melaporkannya sebagai lari.
                jeda = np.maximum((frame[1:] - frame[:-1]) / fps, 1e-6)
                laju = np.append(jarak / jeda, (jarak / jeda)[-1])
            else:
                laju = np.full(len(norm), np.nan)

            for i, titik in enumerate(norm):
                z = next((z for z in zones if dalam_zona(titik, z)), None)
                if z is None:
                    luar += dt
                    continue
                total[z["code"]] += dt
                if laju[i] == laju[i] and laju[i] < AMBANG_DIAM_MS:
                    diam[z["code"]] += dt

        print(f"\n=== {label} ===")
        print(f"{'zona':6} {'waktu-orang':>12} {'porsi diam':>11}   tafsiran")
        for z in sorted(zones, key=lambda z: -total[z["code"]]):
            k = z["code"]
            if total[k] < dt:
                continue
            porsi = diam[k] / total[k]
            if porsi >= 0.6:
                tafsir = "orang berlama-lama"
            elif porsi >= 0.3:
                tafsir = "campuran"
            else:
                tafsir = "jalur lewat"
            print(f"{k:6} {total[k]:9.1f} dtk {porsi:10.0%}   {tafsir}")
        print(f"{'(luar)':6} {luar:9.1f} dtk")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    hitung(sys.argv[1])
