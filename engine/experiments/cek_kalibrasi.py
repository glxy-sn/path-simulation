"""Periksa sehat-tidaknya kalibrasi kamera, sebelum percaya angkanya.

Dipakai setelah mengklik ulang titik di layar Kalibrasi: jalankan ini pada
folder larinya, dan dia menjawab "sudah sehat" atau "belum" beserta alasannya.

    python engine/experiments/cek_kalibrasi.py ~/Documents/crowdflow/run-<id>

Kenapa perlu: homografi punya 8 derajat kebebasan, dan 4 titik memberi tepat 8
persamaan. Dengan 4 inlier, homografi melewati semua titik SECARA SEMPURNA
karena wajib, bukan karena benar — median_error keluar ~1e-15 dan itu tampak
seperti kalibrasi sempurna padahal justru tidak teruji sama sekali. Yang ke-5
dan seterusnya barulah menguji. Skrip ini menolak percaya error nol.
"""
import json
import sys
from pathlib import Path

import numpy as np

# Ambang penilaian. Longgar, tapi cukup untuk menangkap kalibrasi yang ngawur.
MIN_INLIER_SEHAT = 6        # 4 = tidak teruji, 5 = satu penguji, 6+ = layak
MAX_MEDIAN_ERROR_M = 0.15
MAX_P95_ERROR_M = 0.60
ERROR_TERLALU_NOL = 1e-9    # di bawah ini bukan akurasi, tapi overfit


def _proyeksi(H, pts_px):
    p = np.hstack([np.asarray(pts_px, float), np.ones((len(pts_px), 1))])
    w = p @ np.asarray(H, float).T
    z = w[:, 2:3]
    z[np.abs(z) < 1e-12] = np.nan
    return w[:, :2] / z


def periksa_kamera(cam, bounds, jejak_px=None):
    """Kembalikan (nama, daftar_temuan, sehat)."""
    label = cam.get("label", "?")
    cal = cam["calibration"]
    H = cal["H_cam_to_world"]
    m = cal.get("metrics", {})
    n_titik = m.get("points", len(cal.get("camera_points_px", [])))
    n_in = m.get("inliers", 0)
    med = m.get("median_error_m")
    p95 = m.get("p95_error_m")

    temuan = []
    sehat = True

    if n_in < 4:
        temuan.append(f"GAGAL  inlier {n_in} — homografi tidak bisa dihitung")
        sehat = False
    elif n_in == 4:
        temuan.append(
            f"GAGAL  inlier 4 dari {n_titik} titik — jumlah minimum mutlak. "
            "Homografi pas melewati keempatnya karena wajib, jadi errornya "
            "tidak berarti apa-apa. Tambah titik.")
        sehat = False
    elif n_in < MIN_INLIER_SEHAT:
        temuan.append(
            f"RAGU   inlier {n_in} dari {n_titik} titik — hanya "
            f"{n_in - 4} titik penguji. Sebaiknya {MIN_INLIER_SEHAT}+.")
        sehat = False
    else:
        temuan.append(f"ok     inlier {n_in} dari {n_titik} titik")

    if med is not None:
        if med < ERROR_TERLALU_NOL:
            temuan.append(
                f"GAGAL  median error {med:.2e} m — nol palsu, ciri titik "
                "terlalu sedikit. Kalibrasi yang jujur menyisakan error.")
            sehat = False
        elif med > MAX_MEDIAN_ERROR_M:
            temuan.append(f"GAGAL  median error {med:.3f} m — di atas "
                          f"{MAX_MEDIAN_ERROR_M} m")
            sehat = False
        else:
            temuan.append(f"ok     median error {med:.3f} m")

    if p95 is not None:
        if p95 > MAX_P95_ERROR_M:
            temuan.append(f"RAGU   p95 error {p95:.3f} m — ada titik yang "
                          f"meleset jauh (batas {MAX_P95_ERROR_M} m)")
            sehat = False
        else:
            temuan.append(f"ok     p95 error {p95:.3f} m")

    # Suku perspektif. Nilai besar membuat proyeksi meledak jauh dari titik
    # kalibrasi — gejalanya orang "menembus dinding" di denah.
    h3 = np.abs(np.asarray(H, float)[2, :2]).max()
    if h3 > 1e-3:
        temuan.append(f"RAGU   suku perspektif {h3:.2e} — besar; proyeksi "
                      "rawan meledak di tepi. Sebar titik sampai ke tengah.")
        sehat = False
    else:
        temuan.append(f"ok     suku perspektif {h3:.2e}")

    # Ke mana titik kalibrasi sendiri tersebar di lantai?
    fm = np.asarray(cal.get("floor_points_m", []), float)
    if len(fm):
        W, Hh = bounds["width"], bounds["height"]
        tengah = ((fm[:, 0] > 0.25 * W) & (fm[:, 0] < 0.75 * W) &
                  (fm[:, 1] > 0.25 * Hh) & (fm[:, 1] < 0.75 * Hh)).sum()
        if tengah == 0:
            temuan.append("RAGU   tidak ada titik di sepertiga tengah ruangan "
                          "— semua menempel tepi, area jalan tidak terkendala")
            sehat = False
        else:
            temuan.append(f"ok     {tengah} titik berada di tengah ruangan")

    # Apakah jejak sungguhan mendarat di dalam ruangan?
    if jejak_px is not None and len(jejak_px):
        w = _proyeksi(H, jejak_px)
        w = w[~np.isnan(w).any(axis=1)]
        if len(w):
            luar = ((w[:, 0] < 0) | (w[:, 0] > bounds["width"]) |
                    (w[:, 1] < 0) | (w[:, 1] > bounds["height"]))
            pct = 100.0 * luar.mean()
            rng = (f"x {w[:, 0].min():.2f}..{w[:, 0].max():.2f} | "
                   f"y {w[:, 1].min():.2f}..{w[:, 1].max():.2f} m")
            # Seberapa JAUH keluarnya, bukan cuma seberapa sering. Satu orang
            # yang diproyeksikan 2 m menembus dinding sudah membuktikan
            # homografinya meleset, walau cuma 0,3% dari titik.
            lebih = max(
                0.0, float(w[:, 0].min()) * -1, float(w[:, 1].min()) * -1,
                float(w[:, 0].max()) - bounds["width"],
                float(w[:, 1].max()) - bounds["height"])
            if lebih > 0.5:
                temuan.append(f"GAGAL  jejak keluar ruangan sejauh {lebih:.2f} m "
                              f"({pct:.1f}% titik) — {rng}")
                sehat = False
            elif pct > 1.0:
                temuan.append(f"RAGU   {pct:.1f}% titik jejak tepat di batas "
                              f"ruangan ({rng})")
                sehat = False
            else:
                temuan.append(f"ok     jejak di dalam ruangan ({rng})")

    return label, temuan, sehat


def konsistensi(cams, per_cam_pts, bounds):
    """Seberapa jauh orang yang sama mendarat berbeda antar kamera."""
    if len(per_cam_pts) < 2:
        return
    print("\n— konsistensi antar kamera —")
    peta = {}
    for cam, (label, byframe) in zip(cams, per_cam_pts):
        H = cam["calibration"]["H_cam_to_world"]
        d = {}
        for f, pts in byframe.items():
            w = _proyeksi(H, pts)
            w = w[~np.isnan(w).any(axis=1)]
            if len(w):
                d[f] = w
        peta[label] = d

    (la, da), (lb, db) = list(peta.items())[:2]
    sama = sorted(set(da) & set(db))
    if not sama:
        print("  tidak ada frame yang beririsan — tidak bisa diperiksa")
        return
    jarak = []
    for f in sama:
        for p in da[f]:
            jarak.append(float(np.hypot(*(db[f] - p).T).min()))
    jarak = np.asarray(jarak)
    med = float(np.median(jarak))
    print(f"  {la} vs {lb}: {len(sama)} frame beririsan")
    print(f"  jarak ke orang TERDEKAT di kamera lain, median {med:.2f} m "
          f"(kuartil {np.percentile(jarak, 25):.2f}–"
          f"{np.percentile(jarak, 75):.2f} m)")
    # Angka ini BATAS BAWAH, bukan ukuran ketidakcocokan sesungguhnya: yang
    # terdekat belum tentu orang yang sama, dan makin ramai ruangan makin kecil
    # angkanya tanpa kalibrasi membaik sedikit pun. Jadi kecil TIDAK
    # membuktikan berimpit; hanya besar yang membuktikan tidak berimpit.
    if med > 1.0:
        print(f"  GAGAL  {med:.2f} m — bahkan tetangga terdekat pun sejauh ini, "
              "jadi kedua kamera pasti tidak berimpit di lantai.")
    else:
        print(f"  (batas bawah {med:.2f} m — tidak membuktikan apa-apa sendirian; "
              "yang menentukan tetap error per kamera di atas)")


def main(folder):
    folder = Path(folder).expanduser()
    kal = None
    for p in sorted(folder.rglob("kalibrasi.json")):
        kal = json.load(open(p))
        print(f"kalibrasi: {p}")
        break
    if kal is None:
        sys.exit(f"tidak ada kalibrasi.json di {folder}")

    bounds = kal.get("world_bounds_m", {"width": 10.0, "height": 7.5})
    print(f"ruangan  : {bounds['width']} x {bounds['height']} m\n")

    # Titik kaki per kamera, untuk menguji proyeksi dengan data sungguhan.
    per_cam = []
    jejak_px = {}
    for sub in sorted(folder.iterdir()):
        hasil = sub / "hasil.json"
        if not hasil.is_dir() and hasil.exists():
            d = json.load(open(hasil))
            label = json.load(open(sub / "kamera.json"))["label"]
            cam = next((c for c in kal["cameras"] if c["label"] == label), None)
            if cam is None:
                continue
            W, Hh = cam["image_size"]["width"], cam["image_size"]["height"]
            byframe, semua = {}, []
            for pts in d.get("jejakWaktu", {}).values():
                for f, nx, ny in pts:
                    byframe.setdefault(f, []).append([nx * W, ny * Hh])
                    semua.append([nx * W, ny * Hh])
            jejak_px[label] = np.asarray(semua, float)
            per_cam.append((label, {k: np.asarray(v, float)
                                    for k, v in byframe.items()}))

    semua_sehat = True
    for cam in kal["cameras"]:
        label, temuan, sehat = periksa_kamera(
            cam, bounds, jejak_px.get(cam.get("label")))
        print(f"— {label} —")
        for t in temuan:
            print("  " + t)
        print(f"  => {'SEHAT' if sehat else 'PERLU DIKALIBRASI ULANG'}\n")
        semua_sehat &= sehat

    konsistensi(kal["cameras"], per_cam, bounds)
    print("\n" + ("SEMUA KAMERA SEHAT" if semua_sehat
                  else "ADA KAMERA YANG PERLU DIKALIBRASI ULANG"))
    return 0 if semua_sehat else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
