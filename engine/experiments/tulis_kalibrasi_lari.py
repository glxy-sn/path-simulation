"""Tulis `kalibrasi.json` ke folder lari, untuk lari yang dibuat di luar aplikasi.

Kenapa berkas ini penting, dan kenapa hilangnya tidak kelihatan:

Layar Hasil menggabungkan dua kamera HANYA kalau tiap kamera punya homografi,
ukuran frame, dan ukuran ruangan (`adaDenah`). Ketiganya dibaca aplikasi dari
`kalibrasi.json` di folder lari. Aplikasi menulisnya sendiri saat analisis
dijalankan dari dalam aplikasi — jadi lari yang kubuat lewat terminal tidak
punya berkas itu, dan layar Hasil diam-diam jatuh ke satu kamera saja. Tidak ada
pesan galat: kamera kedua cuma tidak ada.

Homografinya dihitung `pipeline.homography` milik Shafa, bukan hitungan sendiri,
supaya angka di layar sama persis dengan yang dipakai pipeline saat memproses.

    python engine/experiments/tulis_kalibrasi_lari.py <job.json> <run-id>
"""
import base64
import json
import sys
import uuid
from pathlib import Path

BACKEND = Path("/Users/fitrimaharani/APPLE INSTITUTE/backend-shafa")
KELUARAN = Path.home() / "Documents/crowdflow"


def ukuran_video(path: str) -> tuple[int, int]:
    import cv2
    cap = cv2.VideoCapture(path)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    return w, h


DENAH_BAWAAN = Path.home() / "Downloads/calibrate-tiara.foodcourtcalibration/floorplan.jpeg"


def tulis(job_path: str, run_id: str, denah_path: str | None = None) -> Path:
    import cv2
    denah = Path(denah_path or DENAH_BAWAAN).expanduser()
    if not denah.is_file():
        raise SystemExit(f"denah tidak ditemukan: {denah}")
    img = cv2.imread(str(denah))
    if img is None:
        raise SystemExit(f"denah tidak bisa dibaca: {denah}")
    denah_px = (img.shape[1], img.shape[0])

    sys.path.insert(0, str(BACKEND))
    from pipeline.homography import homography_pixel_to_meter
    from models import JobRequest

    # Lewat JobRequest, bukan dict mentah: fungsi homografi Shafa membaca
    # `p.x`, jadi dict langsung ditolak.
    req = JobRequest(**json.loads(Path(job_path).read_text()))
    lebar_m, tinggi_m = req.venue.widthM, req.venue.heightM

    kamera = []
    for c in req.cameras:
        W, H = ukuran_video(c.videoPath)
        Hm = homography_pixel_to_meter(c.imagePoints, c.planePoints,
                                       W, H, lebar_m, tinggi_m)
        # Titik disimpan dalam PIKSEL: aplikasi memakainya untuk menggambar
        # ulang tanda kalibrasi di atas frame, dan frame itu berukuran piksel.
        titik_px = [[p.x * W, p.y * H] for p in c.imagePoints]
        titik_m = [[p.x * lebar_m, p.y * tinggi_m] for p in c.planePoints]
        titik_denah_px = [[p.x * denah_px[0], p.y * denah_px[1]] for p in c.planePoints]
        n = len(titik_px)
        kamera.append({
            "camera_id": str(uuid.uuid4()),
            "label": c.label or f"Kamera {len(kamera) + 1}",
            "reference_frame_seconds": float(c.startSec or 0),
            "image_size": {"width": W, "height": H},
            "calibration": {
                "H_cam_to_world": [list(map(float, r)) for r in Hm],
                "camera_points_px": titik_px,
                # Titik yang sama, dinyatakan dalam piksel denah — dipakai
                # layar Kalibrasi untuk menggambar ulang tandanya di atas denah.
                "floor_points_px": titik_denah_px,
                "floor_points_m": titik_m,
                "projected_floor_points_px": [],
                "inlier_mask": [True] * n,
                "reprojection_errors_m": [0.0] * n,
                # Galat SENGAJA nol: kita tidak mengukurnya di sini. Layar
                # Kalibrasi menampilkan angka ini, jadi jangan dibaca sebagai
                # "kalibrasi sempurna" — lihat catatan di memori soal galat nol
                # yang menyesatkan.
                "metrics": {"median_error_m": 0.0, "p95_error_m": 0.0,
                            "inliers": n, "points": n},
            },
        })

    folder = Path(run_id) if run_id.startswith("/") else KELUARAN / run_id
    dw, dh = denah_px

    # Denah DISALIN ke folder lari, bukan dirujuk di tempat asalnya. Aplikasi
    # berjalan di kotak pasir dan cuma boleh membaca Documents/crowdflow —
    # menunjuk ke ~/Downloads akan gagal DIAM-DIAM, dan yang terlihat cuma
    # panel denah kosong tanpa satu pun pesan.
    salinan = folder / denah.name
    salinan.write_bytes(denah.read_bytes())

    profil = {
        "schema_version": 1,
        "world_bounds_m": {"width": lebar_m, "height": tinggi_m},
        "floorplan": {
            "source_name": denah.name,
            "pixel_size": {"width": dw, "height": dh},
            "uses_canvas": False,
            "image_path": str(salinan),
            # Disematkan juga: kalau lintasannya suatu saat tidak terbaca,
            # gambarnya tetap ada di dalam profil.
            "image_data": base64.b64encode(salinan.read_bytes()).decode(),
        },
        "H_floor_to_world": [[lebar_m / dw, 0, 0], [0, tinggi_m / dh, 0], [0, 0, 1]],
        "H_world_to_floor": [[dw / lebar_m, 0, 0], [0, dh / tinggi_m, 0], [0, 0, 1]],
        "cameras": kamera,
    }

    berkas = folder / "kalibrasi.json"
    berkas.write_text(json.dumps(profil, indent=1))
    return berkas


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    p = tulis(sys.argv[1], sys.argv[2],
              sys.argv[3] if len(sys.argv) > 3 else None)
    print(f"ditulis: {p} ({p.stat().st_size} byte)")
