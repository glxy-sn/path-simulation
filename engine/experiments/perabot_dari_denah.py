"""Baca gambar denah, temukan perabotnya, tulis `perabot.json` dalam METER.

Kenapa ini ada: peta perabot chatbot dulu KUKETIK TANGAN dari melihat denah.
Untuk ruangan ini saja ketikan itu meleset — konter salah hampir satu meter,
dan titik henti di tepi konter jadi salah nama. Untuk ruangan lain, ketikan itu
bukan cuma meleset, tapi bohong: koordinatnya tetap berlaku dan chatbot akan
menyebut "meja panjang tengah" untuk tempat yang mungkin dapur.

Yang membuat ini bisa tepat: `kalibrasi.json` menyimpan ukuran ruangan dalam
meter dan ukuran denah dalam piksel, jadi tiap blok yang ditemukan bisa
dikonversi ke meter tanpa satu angka pun diketik manual.

NAMA tetap perlu orang. Bentuk bisa dideteksi; "ini meja atau rak" tidak.
Skrip ini menebak dari ukuran dan letak, lalu kamu perbaiki nama dan jenisnya.

    python engine/experiments/perabot_dari_denah.py <run-id> [keluaran.json]
"""
import json
import sys
from pathlib import Path

KELUARAN = Path.home() / "Documents/crowdflow"


def cari_blok(gambar_path: Path, lebar_m: float, tinggi_m: float) -> list[dict]:
    import cv2
    import numpy as np

    img = cv2.imread(str(gambar_path))
    if img is None:
        raise SystemExit(f"denah tidak terbaca: {gambar_path}")
    H, W = img.shape[:2]
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    # Perabot digambar sebagai blok abu-abu terisi; dinding hitam tipis, lantai
    # putih. Ambang menengah memisahkan blok dari keduanya sekaligus.
    mask = cv2.inRange(g, 100, 210)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    n, _, stats, _ = cv2.connectedComponentsWithStats(mask, 8)

    blok = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        if area < (W * H) * 0.002:            # remah
            continue
        if w > W * 0.95 or h > H * 0.95:      # bingkai gambar
            continue
        lm, tm = w / W * lebar_m, h / H * tinggi_m
        # Garis setipis ini bukan perabot — biasanya dinding atau arsiran.
        if min(lm, tm) < 0.25:
            continue
        # Blok yang menutupi hampir seluruh ruangan adalah garis luar ruangan,
        # bukan perabot. Tanpa saringan ini seluruh lantai jadi satu "meja".
        if lm * tm > 0.5 * lebar_m * tinggi_m:
            continue
        blok.append({
            "x0": round(x / W * lebar_m, 2), "y0": round(y / H * tinggi_m, 2),
            "x1": round((x + w) / W * lebar_m, 2), "y1": round((y + h) / H * tinggi_m, 2),
            "lebar_m": round(lm, 2), "tinggi_m": round(tm, 2),
        })
    blok.sort(key=lambda b: -(b["lebar_m"] * b["tinggi_m"]))
    return blok


def tebak_nama(b: dict, lebar_m: float, tinggi_m: float, urut: int) -> tuple[str, str]:
    """Tebakan awal — WAJIB dikoreksi orang. Bentuk bisa diukur, nama tidak."""
    cx = (b["x0"] + b["x1"]) / 2
    lm, tm = b["lebar_m"], b["tinggi_m"]
    sisi = "kiri" if cx < lebar_m / 3 else "kanan" if cx > 2 * lebar_m / 3 else "tengah"
    if lm > 4 and tm < 2:                       # memanjang di sisi bawah/atas
        return (f"konter sisi {'bawah' if b['y0'] > tinggi_m / 2 else 'atas'}",
                "layanan")
    if tm > 3 and lm < 1.5:                      # tinggi dan tipis
        return f"rak sisi {sisi}", "lewat"
    if 1 < lm < 3 and 1 < tm < 4:
        return f"meja {sisi}", "duduk"
    return f"perabot {urut}", "duduk"


def peta_dari_lari(run_id: str) -> list[tuple]:
    """Peta perabot satu lari, diukur langsung dari denahnya.

    Dipakai chatbot tanpa berkas perantara: video baru cukup diproses seperti
    biasa, dan namanya langsung ada. Menyimpan `perabot.json` lebih dulu berarti
    satu langkah manual yang gampang terlupa — dan kalau terlupa, chatbot diam-
    diam kembali memakai peta ruangan yang lain.
    """
    folder = KELUARAN / run_id
    kal = next((p for p in [folder / "kalibrasi.json",
                            folder / "kamera-1/kalibrasi.json"] if p.is_file()), None)
    if kal is None:
        return []
    prof = json.loads(kal.read_text())
    lebar_m = prof["world_bounds_m"]["width"]
    tinggi_m = prof["world_bounds_m"]["height"]
    denah = (prof.get("floorplan") or {}).get("image_path")
    if not denah or not Path(denah).is_file():
        return []
    peta = []
    for i, b in enumerate(cari_blok(Path(denah), lebar_m, tinggi_m), 1):
        nama, jenis = tebak_nama(b, lebar_m, tinggi_m, i)
        peta.append((nama, b["x0"], b["y0"], b["x1"], b["y1"], jenis))
    return peta


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    run = sys.argv[1]
    folder = KELUARAN / run
    kal = next((p for p in [folder / "kalibrasi.json",
                            folder / "kamera-1/kalibrasi.json"] if p.is_file()), None)
    if kal is None:
        raise SystemExit(f"kalibrasi.json tidak ada di {folder}")
    prof = json.loads(kal.read_text())
    lebar_m = prof["world_bounds_m"]["width"]
    tinggi_m = prof["world_bounds_m"]["height"]

    denah = prof["floorplan"].get("image_path")
    if not denah or not Path(denah).is_file():
        raise SystemExit("profil tidak menunjuk ke gambar denah yang ada")

    blok = cari_blok(Path(denah), lebar_m, tinggi_m)
    perabot = []
    for i, b in enumerate(blok, 1):
        nama, jenis = tebak_nama(b, lebar_m, tinggi_m, i)
        perabot.append({"nama": nama, "jenis": jenis, **b})

    keluaran = Path(sys.argv[2]) if len(sys.argv) > 2 else folder / "perabot.json"
    keluaran.write_text(json.dumps(
        {"ruangan_m": [lebar_m, tinggi_m],
         "catatan": "NAMA dan JENIS masih tebakan — perbaiki manual. "
                    "jenis: duduk | lewat | layanan",
         "perabot": perabot}, indent=1))

    print(f"{len(perabot)} perabot ditemukan -> {keluaran}\n")
    for p in perabot:
        print(f"  {p['nama']:24} {p['jenis']:8} "
              f"({p['x0']:.1f},{p['y0']:.1f})-({p['x1']:.1f},{p['y1']:.1f}) m")
    print("\nPeriksa nama dan jenisnya, lalu sunting berkas itu.")


if __name__ == "__main__":
    main()
