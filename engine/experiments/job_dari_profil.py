"""Susun `job.json` dari profil kalibrasi aplikasi (`profile.json`).

Dipakai supaya pipeline memproses dengan kalibrasi yang BENAR-BENAR dipilih,
bukan kalibrasi lama yang kebetulan masih tersimpan di job.json.

Titik disimpan berbeda di dua tempat, dan ini sumber kekeliruan yang mahal:
profil menyimpan PIKSEL (titik kamera relatif ukuran frame, titik lantai
relatif ukuran gambar denah), sedangkan job.json memakai 0–1. Ukuran frame di
profil juga bisa berbeda dari videonya — Tiara mengklik di 4608x2592 sementara
videonya 2304x1296 — jadi menyalin piksel apa adanya akan menggeser semua titik
dua kali lipat. Karena itu semuanya dinormalkan lebih dulu.

    python engine/experiments/job_dari_profil.py <profile.json> <job_lama.json> <keluaran.json>
"""
import json
import sys
from pathlib import Path


def susun(profil_path: str, job_lama_path: str, keluaran: str) -> Path:
    prof = json.loads(Path(profil_path).read_text())
    job = json.loads(Path(job_lama_path).read_text())

    dw = prof["floorplan"]["pixel_size"]["width"]
    dh = prof["floorplan"]["pixel_size"]["height"]

    kamera_baru = []
    for i, cam_lama in enumerate(job["cameras"]):
        if i >= len(prof["cameras"]):
            raise SystemExit(f"profil cuma punya {len(prof['cameras'])} kamera")
        pc = prof["cameras"][i]
        kal = pc["calibration"]
        fw = pc["image_size"]["width"]
        fh = pc["image_size"]["height"]

        # Video, jendela waktu, dan label diambil dari job lama: yang diganti
        # cuma kalibrasinya.
        baru = dict(cam_lama)
        baru["imagePoints"] = [{"x": p[0] / fw, "y": p[1] / fh}
                               for p in kal["camera_points_px"]]
        baru["planePoints"] = [{"x": p[0] / dw, "y": p[1] / dh}
                               for p in kal["floor_points_px"]]
        n = len(baru["imagePoints"])
        if n != len(baru["planePoints"]):
            raise SystemExit(f"kamera {i+1}: titik kamera {n} != titik denah "
                             f"{len(baru['planePoints'])}")
        if n < 4:
            raise SystemExit(f"kamera {i+1}: cuma {n} titik, homografi butuh 4")
        kamera_baru.append(baru)
        print(f"  {baru.get('label')}: {n} titik dari profil")

    job["cameras"] = kamera_baru
    job["venue"] = {**job["venue"],
                    "widthM": prof["world_bounds_m"]["width"],
                    "heightM": prof["world_bounds_m"]["height"]}
    out = Path(keluaran)
    out.write_text(json.dumps(job, indent=1))
    return out


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    p = susun(sys.argv[1], sys.argv[2], sys.argv[3])
    print(f"ditulis: {p}")
