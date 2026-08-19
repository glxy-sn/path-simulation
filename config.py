"""Konfigurasi engine; semua nilai dapat dioverride melalui environment PRISM_* ."""

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


def _float_env(primary: str, default: str, legacy: str | None = None) -> float:
    raw = os.getenv(primary)
    if raw is None and legacy:
        raw = os.getenv(legacy)
    return float(raw if raw is not None else default)


class Config:
    HOST = os.getenv("PRISM_SIDECAR_HOST", "127.0.0.1")
    PORT = int(os.getenv("PRISM_SIDECAR_PORT", "8765"))

    DEVICE = _default_device()
    HALF = False

    # 19 Agt 2026: detektor analisis disamakan dengan yang ditulis di laporan
    # (YOLO11s). Hasil dari sebelum tanggal ini dibuat dengan yolo11x dan tidak
    # bisa dibandingkan langsung dengan hasil baru.
    YOLO_MODEL = os.getenv("PRISM_YOLO", "yolo11s.pt")
    IMGSZ = int(os.getenv("PRISM_IMGSZ", "1920"))
    CONF = float(os.getenv("PRISM_CONF", "0.10"))
    IOU = float(os.getenv("PRISM_IOU", "0.70"))
    PERSON_CLASS = 0

    REID_WEIGHTS = os.getenv("PRISM_REID", "osnet_x0_25_msmt17.pt")
    WITH_REID = os.getenv("PRISM_WITH_REID", "1") != "0"
    REID_DEVICE = os.getenv("PRISM_REID_DEVICE", "cpu")
    REID_SAMPLE_CONF = float(os.getenv("PRISM_REID_SAMPLE_CONF", "0.5"))
    REID_SAMPLE_BIN_SEC = float(os.getenv("PRISM_REID_SAMPLE_BIN_SEC", "1.0"))
    REID_MAX_SAMPLES = int(os.getenv("PRISM_REID_MAX_SAMPLES", "12"))
    REID_MIN_SAMPLES = int(os.getenv("PRISM_REID_MIN_SAMPLES", "3"))

    PREVIEW_YOLO_MODEL = os.getenv("PRISM_PREVIEW_YOLO", "yolo11s.pt")
    PREVIEW_IMGSZ = int(os.getenv("PRISM_PREVIEW_IMGSZ", "960"))
    PREVIEW_SAMPLE_DELTA_SEC = float(os.getenv("PRISM_PREVIEW_DELTA", "0.5"))
    PREVIEW_CACHE_TTL_SEC = float(os.getenv("PRISM_PREVIEW_CACHE_TTL", "600"))
    PREVIEW_CACHE_MAX = int(os.getenv("PRISM_PREVIEW_CACHE_MAX", "8"))

    PROC_FPS = float(os.getenv("PRISM_PROC_FPS", "5"))
    BATCH_SIZE = int(os.getenv("PRISM_BATCH", "8"))
    MAX_DURATION_SEC = float(os.getenv("PRISM_MAX_DURATION_SEC", "600"))

    # Friend fix 5cda6c9: cross-camera appearance matching with a wider spatial gate.
    R_MERGE_M = float(os.getenv("PRISM_R_MERGE_M", "1.0"))
    MERGE_MIN_OVERLAP_SEC = float(os.getenv("PRISM_MERGE_OVERLAP", "0.5"))
    WITH_APP_FUSION = os.getenv("PRISM_APP_FUSION", "1") != "0"
    R_MERGE_APP_M = float(os.getenv("PRISM_R_MERGE_APP_M", "2.5"))
    APP_THRESH = float(os.getenv("PRISM_APP_THRESH", "0.7"))

    # Local fragment stitching. Legacy variables remain fallback-compatible.
    LOCAL_STITCH_MAX_GAP_SEC = _float_env(
        "PRISM_LOCAL_STITCH_GAP", "2.0", legacy="PRISM_STITCH_GAP"
    )
    LOCAL_STITCH_MAX_DIST_M = _float_env(
        "PRISM_LOCAL_STITCH_DIST", "1.5", legacy="PRISM_STITCH_DIST"
    )
    LOCAL_STITCH_MAX_SPEED_MPS = float(os.getenv("PRISM_LOCAL_STITCH_SPEED", "2.0"))
    LOCAL_STITCH_MIN_SIM = float(os.getenv("PRISM_LOCAL_STITCH_SIM", "0.70"))

    # Cross-camera overlap and handover association.
    OVERLAP_BASE_RADIUS_M = float(
        os.getenv("PRISM_OVERLAP_BASE_RADIUS", str(R_MERGE_M))
    )
    OVERLAP_APPEARANCE_RADIUS_M = float(
        os.getenv("PRISM_OVERLAP_APP_RADIUS", str(R_MERGE_APP_M))
    )
    OVERLAP_MIN_SEC = float(
        os.getenv("PRISM_OVERLAP_MIN_SEC", str(MERGE_MIN_OVERLAP_SEC))
    )
    OVERLAP_MIN_SIM = float(os.getenv("PRISM_OVERLAP_MIN_SIM", str(APP_THRESH)))
    HANDOVER_MAX_GAP_SEC = float(os.getenv("PRISM_HANDOVER_GAP", "15.0"))
    HANDOVER_MAX_SPEED_MPS = float(os.getenv("PRISM_HANDOVER_SPEED", "2.0"))
    HANDOVER_MIN_SIM = float(os.getenv("PRISM_HANDOVER_MIN_SIM", "0.68"))

    MIN_TRACK_SEC = float(os.getenv("PRISM_MIN_TRACK_SEC", "1.5"))
    MIN_TRACK_POINTS = int(os.getenv("PRISM_MIN_TRACK_POINTS", "3"))

    CALIBRATION_INLIER_THRESHOLD_M = float(os.getenv("PRISM_CALIB_INLIER_M", "0.25"))
    CALIBRATION_WARN_INLIER_RATIO = float(os.getenv("PRISM_CALIB_WARN_INLIER", "0.75"))
    CALIBRATION_WARN_MEDIAN_M = float(os.getenv("PRISM_CALIB_WARN_MEDIAN", "0.15"))
    CALIBRATION_WARN_P95_M = float(os.getenv("PRISM_CALIB_WARN_P95", "0.40"))
    CALIBRATION_WARN_IMAGE_COVERAGE = float(os.getenv("PRISM_CALIB_WARN_IMAGE_COVERAGE", "0.10"))
    CALIBRATION_WARN_PLANE_COVERAGE = float(os.getenv("PRISM_CALIB_WARN_PLANE_COVERAGE", "0.15"))

    OCC_BIN_SEC = int(os.getenv("PRISM_OCC_BIN", "60"))
    HEAT_GRID = (64, 48)
    BLOB_MAX = int(os.getenv("PRISM_BLOB_MAX", "28"))
    BLOB_RADIUS = float(os.getenv("PRISM_BLOB_RADIUS", "0.06"))
    PATH_MAX = int(os.getenv("PRISM_PATH_MAX", "12"))
    ZONE_GRID = (int(os.getenv("PRISM_ZONE_COLS", "3")), int(os.getenv("PRISM_ZONE_ROWS", "2")))
    ZONE_MAX = 6
    STOP_SPEED_MPS = float(os.getenv("PRISM_STOP_SPEED", "0.3"))
    STOP_MIN_SEC = float(os.getenv("PRISM_STOP_MIN", "3"))
    STOP_MERGE_M = 1.0
    STOP_MAX = 6

    WORKDIR = _workdir()
    RENDER_VIDEOS_DEFAULT = True
