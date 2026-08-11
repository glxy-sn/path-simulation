"""Validation and conversion for normalized-image -> floor homographies."""
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class CalibrationEvaluation:
    pixel_to_world: np.ndarray
    normalized_to_world: np.ndarray
    inlier_mask: list[bool]
    median_error_m: float
    p95_error_m: float
    image_coverage: float
    plane_coverage: float
    warnings: list[str]
    legacy_calibration: bool
    client_metric_differences: dict[str, float]

    @property
    def uncertainty_m(self) -> float:
        # Never let a mathematically exact four-point fit claim zero uncertainty.
        return max(0.05, self.p95_error_m)


def _validated_homography(value) -> np.ndarray:
    H = np.asarray(value, dtype=np.float64)
    if H.shape != (3, 3):
        raise ValueError("homographyNormToWorld harus berupa matriks 3x3")
    if not np.isfinite(H).all():
        raise ValueError("homographyNormToWorld mengandung nilai non-finite")
    if abs(float(np.linalg.det(H))) < 1e-12 or np.linalg.matrix_rank(H) < 3:
        raise ValueError("homographyNormToWorld singular")
    if abs(float(H[2, 2])) > 1e-12:
        H = H / H[2, 2]
    return H


def _coverage(points: np.ndarray, denominator: float) -> float:
    if len(points) < 3 or denominator <= 0:
        return 0.0
    hull = cv2.convexHull(points.astype(np.float32).reshape(-1, 1, 2))
    return float(cv2.contourArea(hull) / denominator)


def _errors(H_norm: np.ndarray, src_norm: np.ndarray, dst_world: np.ndarray) -> np.ndarray:
    projected = project_points(H_norm, src_norm)
    if not np.isfinite(projected).all():
        raise ValueError("homography menghasilkan proyeksi non-finite")
    return np.linalg.norm(projected.astype(np.float64) - dst_world, axis=1)


def evaluate_calibration(camera, frame_w: int, frame_h: int, venue_w: float, venue_h: float, cfg):
    """Build pixel->world H and independently verify its request-point reprojection."""
    if frame_w <= 0 or frame_h <= 0:
        raise ValueError("resolusi video tidak valid")
    if venue_w <= 0 or venue_h <= 0:
        raise ValueError("dimensi venue tidak valid")

    src_norm = np.asarray([[p.x, p.y] for p in camera.imagePoints], dtype=np.float64)
    dst_world = np.asarray(
        [[p.x * venue_w, p.y * venue_h] for p in camera.planePoints], dtype=np.float64
    )
    if len(src_norm) != len(dst_world):
        raise ValueError("jumlah imagePoints dan planePoints harus sama")

    supplied = camera.calibration
    legacy = supplied is None
    if supplied is not None:
        H_norm = _validated_homography(supplied.homographyNormToWorld)
    else:
        H_norm, _ = cv2.findHomography(
            src_norm.astype(np.float32),
            dst_world.astype(np.float32),
            cv2.RANSAC,
            float(cfg.CALIBRATION_INLIER_THRESHOLD_M),
        )
        if H_norm is None:
            raise ValueError("RANSAC tidak dapat menghitung homography legacy")
        H_norm = _validated_homography(H_norm)

    errors = _errors(H_norm, src_norm, dst_world)
    inlier_mask = errors <= float(cfg.CALIBRATION_INLIER_THRESHOLD_M)
    median = float(np.median(errors))
    p95 = float(np.percentile(errors, 95))
    image_coverage = _coverage(src_norm, 1.0)
    plane_coverage = _coverage(dst_world, venue_w * venue_h)
    inlier_ratio = float(np.mean(inlier_mask))

    warnings = []
    if legacy:
        warnings.append("legacyCalibration")
    if inlier_ratio < cfg.CALIBRATION_WARN_INLIER_RATIO:
        warnings.append("inlierRatioBelow75Percent")
    if median > cfg.CALIBRATION_WARN_MEDIAN_M:
        warnings.append("medianErrorAbove0.15m")
    if p95 > cfg.CALIBRATION_WARN_P95_M:
        warnings.append("p95ErrorAbove0.40m")
    if image_coverage < cfg.CALIBRATION_WARN_IMAGE_COVERAGE:
        warnings.append("cameraPointCoverageBelow10Percent")
    if plane_coverage < cfg.CALIBRATION_WARN_PLANE_COVERAGE:
        warnings.append("floorPointCoverageBelow15Percent")

    differences = {}
    if supplied is not None:
        comparisons = {
            "medianErrorM": (supplied.medianErrorM, median),
            "p95ErrorM": (supplied.p95ErrorM, p95),
            "inliers": (supplied.inliers, int(np.sum(inlier_mask))),
            "points": (supplied.points, len(errors)),
        }
        for name, (client, server) in comparisons.items():
            if client is not None:
                differences[name] = float(client) - float(server)

    # H_norm maps normalized pixels to world. Pixel coordinates must first be divided
    # by the actual video dimensions, preserving calibration across resolutions.
    pixel_scale = np.diag([1.0 / frame_w, 1.0 / frame_h, 1.0])
    H_pixel = _validated_homography(H_norm @ pixel_scale)
    return CalibrationEvaluation(
        pixel_to_world=H_pixel,
        normalized_to_world=H_norm,
        inlier_mask=[bool(v) for v in inlier_mask],
        median_error_m=median,
        p95_error_m=p95,
        image_coverage=image_coverage,
        plane_coverage=plane_coverage,
        warnings=warnings,
        legacy_calibration=legacy,
        client_metric_differences=differences,
    )


def homography_pixel_to_meter(
    image_points, plane_points, frame_w: int, frame_h: int, venue_w: float, venue_h: float
):
    """Legacy helper retained for callers outside the job pipeline, now using RANSAC."""
    src = np.asarray([[p.x, p.y] for p in image_points], dtype=np.float32)
    dst = np.asarray([[p.x * venue_w, p.y * venue_h] for p in plane_points], dtype=np.float32)
    H_norm, _ = cv2.findHomography(src, dst, cv2.RANSAC, 0.25)
    if H_norm is None:
        raise ValueError("tidak dapat menghitung homography")
    return _validated_homography(H_norm @ np.diag([1.0 / frame_w, 1.0 / frame_h, 1.0]))


def project_points(H, pts) -> np.ndarray:
    """Project Nx2 points through H."""
    pts = np.asarray(pts, dtype=np.float32)
    if pts.size == 0:
        return np.empty((0, 2), dtype=np.float32)
    out = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.asarray(H, dtype=np.float64))
    return out.reshape(-1, 2)
