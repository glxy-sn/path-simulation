"""Allowlisted person-detection models exposed by the desktop app."""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


BACKEND_DIR = Path(__file__).resolve().parent
DEFAULT_DETECTION_MODEL_ID = "yolo11s-base"


def _model_path(filename: str, local_path: Path) -> Path:
    """Use downloaded app assets when the packaged sidecar provides them.

    Development keeps using the checkpoints next to this source tree, while the
    distributable macOS app keeps all downloaded weights outside its signed
    bundle in Application Support.
    """
    configured_root = os.getenv("USEE_MODELS_ROOT") or os.getenv("FOODCOURT_MODELS_ROOT")
    if configured_root:
        return Path(configured_root).expanduser() / filename
    return local_path


@dataclass(frozen=True)
class DetectionModelSpec:
    id: str
    label: str
    path: Path


DETECTION_MODELS: dict[str, DetectionModelSpec] = {
    "yolo11s-base": DetectionModelSpec(
        id="yolo11s-base",
        label="YOLO11s",
        path=_model_path("yolo11s.pt", BACKEND_DIR / "yolo11s.pt"),
    ),
    "yolo11s-finetuned-stage2-caviar": DetectionModelSpec(
        id="yolo11s-finetuned-stage2-caviar",
        label="Finetuned Caviar",
        path=_model_path(
            "yolo11s-finetuned-stage2-caviar.pt",
            BACKEND_DIR / "models" / "yolo11s-finetuned-stage2-caviar.pt",
        ),
    ),
}


def resolve_detection_model(model_id: str | None) -> DetectionModelSpec:
    """Return an installed model from the app-facing allowlist.

    Request payloads carry an ID rather than a filesystem path, so a client
    cannot make the backend load arbitrary local weights.
    """
    selected = (model_id or DEFAULT_DETECTION_MODEL_ID).strip()
    spec = DETECTION_MODELS.get(selected)
    if spec is None:
        allowed = ", ".join(DETECTION_MODELS)
        raise ValueError(f"Model deteksi tidak dikenal: '{selected}'. Pilihan: {allowed}")
    if not spec.path.is_file():
        raise ValueError(f"Bobot model '{spec.label}' belum tersedia: {spec.path}")
    return spec
