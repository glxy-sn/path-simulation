"""Shared global-timeline semantics for multi-camera source video access."""


def camera_source_time(camera, global_time_sec: float) -> float:
    """Map a global timeline timestamp to a camera's source-video timestamp."""
    return float(global_time_sec) + float(getattr(camera, "timeOffsetSec", 0.0))


def camera_source_start(camera) -> float:
    return camera_source_time(camera, float(getattr(camera, "startSec", 0.0)))
