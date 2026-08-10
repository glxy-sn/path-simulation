# """
# Konfigurasi engine. Semua bisa dioverride lewat environment variable (PRISM_*).
# Nilai default = konfig detektor yang sudah kamu tetapkan + parameter fusion/analitik
# yang bisa kamu tune.
# """
# import os
# from pathlib import Path


# def _default_device() -> str:
#     if os.getenv("PRISM_DEVICE"):
#         return os.environ["PRISM_DEVICE"]
#     try:
#         import torch
#         if torch.backends.mps.is_available():
#             return "mps"
#         if torch.cuda.is_available():
#             return "cuda"
#     except Exception:
#         pass
#     return "cpu"


# def _workdir() -> Path:
#     raw = os.getenv("PRISM_WORKDIR", "~/Library/Application Support/Foodcourt/work")
#     return Path(raw).expanduser().resolve()


# class Config:
#     # ---- Server ----
#     HOST = os.getenv("PRISM_SIDECAR_HOST", "127.0.0.1")
#     PORT = int(os.getenv("PRISM_SIDECAR_PORT", "8765"))

#     # ---- Device ----
#     DEVICE = _default_device()
#     HALF = False                     # MPS: jangan half

#     # ---- Detektor (konfig yang sudah ditetapkan) ----
#     YOLO_MODEL = os.getenv("PRISM_YOLO", "yolo11x.pt")
#     IMGSZ = int(os.getenv("PRISM_IMGSZ", "1920"))
#     CONF = float(os.getenv("PRISM_CONF", "0.10"))
#     IOU = float(os.getenv("PRISM_IOU", "0.70"))
#     PERSON_CLASS = 0                 # COCO: person
#     # Catatan: di MPS, 11x@1920 berat. Untuk lebih cepat, set PRISM_YOLO=yolo11s.pt
#     # dan/atau PRISM_IMGSZ=1280.

#     # ---- Tracker (BoT-SORT / boxmot) ----
#     REID_WEIGHTS = os.getenv("PRISM_REID", "osnet_x0_25_msmt17.pt")
#     # ReID (OSNet) berat. Fusion antar-kamera kita spasial, jadi ReID cuma untuk
#     # re-id dalam satu kamera. Matikan untuk kecepatan: PRISM_WITH_REID=0
#     WITH_REID = os.getenv("PRISM_WITH_REID", "1") != "0"
#     # OSNet x0_25 sangat kecil -> di MPS sering LEBIH LAMBAT dari CPU (overhead kernel
#     # + MPS fallback per crop). Jalankan ReID di CPU, YOLO tetap di MPS.
#     REID_DEVICE = os.getenv("PRISM_REID_DEVICE", "cpu")
#     # Param BoT-SORT tuned kamu bisa ditambahkan di pipeline/track.py::make_tracker

#     # ---- Sampling ----
#     PROC_FPS = float(os.getenv("PRISM_PROC_FPS", "5"))   # proses ~5 frame/detik
#     BATCH_SIZE = int(os.getenv("PRISM_BATCH", "8"))      # deteksi di-batch (efisiensi MPS)
#     # Batasi tiap video ke N detik pertama (600 = 10 menit). 0 = tanpa batas.
#     MAX_DURATION_SEC = float(os.getenv("PRISM_MAX_DURATION_SEC", "600"))

#     # ---- Fusion multi-kamera (level-track, untuk overlap jarang) ----
#     R_MERGE_M = float(os.getenv("PRISM_R_MERGE_M", "0.6"))          # radius merge (meter)
#     MERGE_MIN_OVERLAP_SEC = float(os.getenv("PRISM_MERGE_OVERLAP", "1.0"))

#     # ---- Analitik ----
#     OCC_BIN_SEC = int(os.getenv("PRISM_OCC_BIN", "60"))            # bin okupansi (detik)
#     HEAT_GRID = (64, 48)                                          # (kolom, baris) grid heatmap
#     ZONE_GRID = (int(os.getenv("PRISM_ZONE_COLS", "3")),
#                  int(os.getenv("PRISM_ZONE_ROWS", "2")))          # (kolom, baris) zona
#     ZONE_MAX = 6
#     STOP_SPEED_MPS = float(os.getenv("PRISM_STOP_SPEED", "0.3"))  # < ini = berhenti
#     STOP_MIN_SEC = float(os.getenv("PRISM_STOP_MIN", "3"))        # durasi minimum stop
#     STOP_MERGE_M = 1.0
#     STOP_MAX = 6

#     # ---- Output ----
#     WORKDIR = _workdir()
#     RENDER_VIDEOS_DEFAULT = True

"""
Konfigurasi engine. Semua bisa dioverride lewat environment variable (PRISM_*).
Nilai default = konfig detektor yang sudah kamu tetapkan + parameter fusion/analitik
yang bisa kamu tune.
"""
import os
from pathlib import Path


def _default_device() -> str:
    if os.getenv("PRISM_DEVICE"):
        return os.environ["PRISM_DEVICE"]
    try:
        import torch
        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def _workdir() -> Path:
    raw = os.getenv("PRISM_WORKDIR", "~/Library/Application Support/Foodcourt/work")
    return Path(raw).expanduser().resolve()


class Config:
    # ---- Server ----
    HOST = os.getenv("PRISM_SIDECAR_HOST", "127.0.0.1")
    PORT = int(os.getenv("PRISM_SIDECAR_PORT", "8765"))

    # ---- Device ----
    DEVICE = _default_device()
    HALF = False                     # MPS: jangan half

    # ---- Detektor (konfig yang sudah ditetapkan) ----
    YOLO_MODEL = os.getenv("PRISM_YOLO", "yolo11x.pt")
    IMGSZ = int(os.getenv("PRISM_IMGSZ", "1920"))
    CONF = float(os.getenv("PRISM_CONF", "0.10"))
    IOU = float(os.getenv("PRISM_IOU", "0.70"))
    PERSON_CLASS = 0                 # COCO: person
    # Catatan: di MPS, 11x@1920 berat. Untuk lebih cepat, set PRISM_YOLO=yolo11s.pt
    # dan/atau PRISM_IMGSZ=1280.

    # ---- Tracker (BoT-SORT / boxmot) ----
    REID_WEIGHTS = os.getenv("PRISM_REID", "osnet_x0_25_msmt17.pt")
    # ReID (OSNet) berat. Fusion antar-kamera kita spasial, jadi ReID cuma untuk
    # re-id dalam satu kamera. Matikan untuk kecepatan: PRISM_WITH_REID=0
    WITH_REID = os.getenv("PRISM_WITH_REID", "1") != "0"
    # OSNet x0_25 sangat kecil -> di MPS sering LEBIH LAMBAT dari CPU (overhead kernel
    # + MPS fallback per crop). Jalankan ReID di CPU, YOLO tetap di MPS.
    REID_DEVICE = os.getenv("PRISM_REID_DEVICE", "cpu")
    # Param BoT-SORT tuned kamu bisa ditambahkan di pipeline/track.py::make_tracker

    # ---- Sampling ----
    PROC_FPS = float(os.getenv("PRISM_PROC_FPS", "5"))   # proses ~5 frame/detik
    BATCH_SIZE = int(os.getenv("PRISM_BATCH", "8"))      # deteksi di-batch (efisiensi MPS)
    # Batasi tiap video ke N detik pertama (600 = 10 menit). 0 = tanpa batas.
    MAX_DURATION_SEC = float(os.getenv("PRISM_MAX_DURATION_SEC", "600"))

    # ---- Fusion multi-kamera (level-track, untuk overlap jarang) ----
    R_MERGE_M = float(os.getenv("PRISM_R_MERGE_M", "0.6"))          # radius merge (meter)
    MERGE_MIN_OVERLAP_SEC = float(os.getenv("PRISM_MERGE_OVERLAP", "1.0"))

    # ---- Analitik ----
    OCC_BIN_SEC = int(os.getenv("PRISM_OCC_BIN", "60"))            # bin okupansi (detik)
    # Buang track pendek (fragmen/false-positive) sebelum analitik & render.
    MIN_TRACK_SEC = float(os.getenv("PRISM_MIN_TRACK_SEC", "1.5"))
    MIN_TRACK_POINTS = int(os.getenv("PRISM_MIN_TRACK_POINTS", "3"))
    # ID stitching: sambung track pecah (gap kecil + posisi lantai dekat).
    STITCH_MAX_GAP_SEC = float(os.getenv("PRISM_STITCH_GAP", "2.0"))
    STITCH_MAX_DIST_M = float(os.getenv("PRISM_STITCH_DIST", "1.5"))
    HEAT_GRID = (64, 48)                                          # (kolom, baris) grid heatmap
    BLOB_MAX = int(os.getenv("PRISM_BLOB_MAX", "28"))             # jumlah titik panas (heatmap UI)
    BLOB_RADIUS = float(os.getenv("PRISM_BLOB_RADIUS", "0.06"))
    PATH_MAX = int(os.getenv("PRISM_PATH_MAX", "12"))            # jumlah lintasan (path UI)
    ZONE_GRID = (int(os.getenv("PRISM_ZONE_COLS", "3")),
                 int(os.getenv("PRISM_ZONE_ROWS", "2")))          # (kolom, baris) zona
    ZONE_MAX = 6
    STOP_SPEED_MPS = float(os.getenv("PRISM_STOP_SPEED", "0.3"))  # < ini = berhenti
    STOP_MIN_SEC = float(os.getenv("PRISM_STOP_MIN", "3"))        # durasi minimum stop
    STOP_MERGE_M = 1.0
    STOP_MAX = 6

    # ---- Output ----
    WORKDIR = _workdir()
    RENDER_VIDEOS_DEFAULT = True