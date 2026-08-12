from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patches import Ellipse, Polygon as MplPolygon
from PIL import Image
from scipy.ndimage import gaussian_filter
from shapely import contains_xy
from shapely.geometry import Point, Polygon, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from skimage.feature import peak_local_max
from skimage.measure import find_contours, label as connected_components
from skimage.segmentation import watershed
from sklearn.cluster import AgglomerativeClustering, HDBSCAN


SCHEMA_VERSION = "2.0"
REQUIRED_TRAJECTORY_COLUMNS = {"t", "id", "x", "y", "identityScore", "identityLevel"}


@dataclass(frozen=True)
class AnalysisConfig:
    backend_root: Path
    workdir: Path
    output_root: Path
    job_id: str | None = None
    gap_sec: float = 1.0
    smoothing_sec: float = 1.0
    max_speed_mps: float = 3.0
    stop_speed_mps: float = 0.3
    stop_min_sec: float = 3.0
    occupancy_bin_sec: int = 10
    density_grid_m: float = 0.05
    density_sigma_m: float = 0.30
    peak_min_distance_m: float = 0.75
    min_area_m2: float = 0.25
    min_area_visitors: int = 2
    max_areas_per_kind: int = 10
    group_distance_m: float = 1.5
    group_heading_deg: float = 45.0
    group_speed_delta_mps: float = 0.5
    group_min_sec: int = 5
    route_points: int = 40
    route_min_length_m: float = 3.0
    route_min_duration_sec: float = 5.0
    route_cluster_distance_m: float = 1.0

    @classmethod
    def default(cls, backend_root: Path | None = None, job_id: str | None = None) -> "AnalysisConfig":
        root = (backend_root or _find_backend_root()).resolve()
        workdir = Path(os.getenv("FOODCOURT_WORKDIR", str(Path.home() / "Library/Application Support/Foodcourt/work"))).expanduser().resolve()
        output_root = Path(os.getenv("FOODCOURT_ANALYSIS_OUTPUT_ROOT", str(root / "notebooks" / "output"))).expanduser().resolve()
        requested = job_id or os.getenv("FOODCOURT_JOB_ID", "").strip() or None
        return cls(root, workdir, output_root, requested)


@dataclass(frozen=True)
class AnalysisResult:
    job_id: str
    output_dir: Path
    venue_fingerprint: str
    summary: dict[str, Any]
    floorplan_path: Path | None
    context_path: Path
    compatible_job_ids: list[str]


def _find_backend_root() -> Path:
    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / "notebooks").is_dir() and (candidate / "pipeline").is_dir() and (candidate / "requirements-analysis.txt").is_file():
            return candidate
    raise RuntimeError("Root be/path-simulation tidak ditemukan.")


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _native(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): _native(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_native(item) for item in value]
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating, float)):
        number = float(value)
        return number if math.isfinite(number) else None
    if isinstance(value, (np.bool_,)):
        return bool(value)
    if isinstance(value, Path):
        return str(value)
    if value is pd.NA:
        return None
    return value


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(_native(value), ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")


def discover_jobs(workdir: Path) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    if not workdir.exists():
        return pd.DataFrame(columns=["jobId", "completedMtime", "trajectoryAvailable"])
    for directory in sorted(path for path in workdir.iterdir() if path.is_dir()):
        job_path = directory / "job.json"
        result_path = directory / "result.json"
        trajectory_path = directory / "trajectories.parquet"
        if not job_path.is_file() or not result_path.is_file():
            continue
        try:
            job = _read_json(job_path)
            result = _read_json(result_path)
        except (OSError, json.JSONDecodeError):
            continue
        venue = job.get("venue") or {}
        rows.append({
            "jobId": directory.name,
            "completedMtime": result_path.stat().st_mtime,
            "venue": venue.get("name") or "(tanpa nama)",
            "widthM": venue.get("widthM"),
            "heightM": venue.get("heightM"),
            "totalVisitors": (result.get("summary") or {}).get("totalVisitors"),
            "globalIds": (result.get("identityQuality") or {}).get("globalIds"),
            "trajectoryAvailable": trajectory_path.is_file(),
        })
    frame = pd.DataFrame(rows)
    return frame.sort_values(["completedMtime", "jobId"], ascending=[False, True]).reset_index(drop=True) if len(frame) else frame


def _select_job(config: AnalysisConfig) -> str:
    jobs = discover_jobs(config.workdir)
    if config.job_id:
        match = jobs.loc[jobs["jobId"] == config.job_id]
        if match.empty:
            raise FileNotFoundError(f"Job {config.job_id} tidak ditemukan di {config.workdir}.")
        if not bool(match.iloc[0]["trajectoryAvailable"]):
            raise FileNotFoundError(f"Job {config.job_id} tidak memiliki trajectories.parquet.")
        return config.job_id
    complete = jobs.loc[jobs["trajectoryAvailable"]]
    if complete.empty:
        raise FileNotFoundError(f"Tidak ada job lengkap di {config.workdir}.")
    return str(complete.iloc[0]["jobId"])


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def venue_fingerprint(floorplan_path: Path | None, width_m: float, height_m: float) -> str:
    digest = hashlib.sha256(f"{width_m:.6f}x{height_m:.6f}".encode())
    if floorplan_path and floorplan_path.is_file():
        with Image.open(floorplan_path) as image:
            normalized = np.asarray(image.convert("L").resize((64, 64), Image.Resampling.LANCZOS), dtype=np.uint8)
            perceptual_bits = normalized >= np.median(normalized)
            digest.update(np.packbits(perceptual_bits).tobytes())
    else:
        digest.update(b"missing-floorplan")
    return digest.hexdigest()[:20]


def _identity_mode(series: pd.Series) -> str | None:
    values = [str(value) for value in series.dropna() if str(value)]
    return Counter(values).most_common(1)[0][0] if values else None


def prepare_trajectory(raw: pd.DataFrame, width_m: float, height_m: float, camera_start_sec: float, config: AnalysisConfig) -> tuple[pd.DataFrame, float]:
    missing = REQUIRED_TRAJECTORY_COLUMNS - set(raw.columns)
    if missing:
        raise ValueError(f"Kolom trajectory hilang: {sorted(missing)}")
    frame = raw.copy()
    for column in ("t", "x", "y", "identityScore"):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    frame = frame.sort_values(["id", "t"], kind="mergesort").reset_index(drop=True)
    frame["finiteObservation"] = np.isfinite(frame[["t", "x", "y"]]).all(axis=1)
    frame["duplicateObservation"] = frame.duplicated(["id", "t"], keep="first")
    frame["inVenue"] = frame["finiteObservation"] & frame["x"].between(0, width_m) & frame["y"].between(0, height_m)
    frame["usableBase"] = frame["finiteObservation"] & ~frame["duplicateObservation"] & frame["inVenue"]
    frame["videoTimeSec"] = camera_start_sec + frame["t"]
    valid_dt = frame.loc[frame["usableBase"]].groupby("id")["t"].diff()
    valid_dt = valid_dt[(valid_dt > 0) & (valid_dt <= config.gap_sec)]
    sample_period = float(valid_dt.median()) if len(valid_dt) else 0.2
    estimated_fps = 1.0 / max(sample_period, 1e-6)
    window = max(3, int(round(config.smoothing_sec * estimated_fps)))
    window += int(window % 2 == 0)
    frame["segmentId"] = pd.Series(pd.NA, index=frame.index, dtype="string")
    for track_id, indices in frame.loc[frame["usableBase"]].groupby("id", sort=True).groups.items():
        part = frame.loc[indices].sort_values("t")
        dt = part["t"].diff()
        number = (dt.isna() | (dt <= 0) | (dt > config.gap_sec)).cumsum()
        frame.loc[part.index, "segmentId"] = [f"{track_id}:{int(item)}" for item in number]
    frame["xSmoothM"] = np.nan
    frame["ySmoothM"] = np.nan
    for _, indices in frame.loc[frame["segmentId"].notna()].groupby("segmentId", sort=True).groups.items():
        part = frame.loc[indices].sort_values("t")
        frame.loc[part.index, "xSmoothM"] = part["x"].rolling(window, center=True, min_periods=1).median().to_numpy()
        frame.loc[part.index, "ySmoothM"] = part["y"].rolling(window, center=True, min_periods=1).median().to_numpy()
    frame["dtSec"] = np.nan
    frame["stepDistanceM"] = np.nan
    frame["speedMps"] = np.nan
    frame["headingDeg"] = np.nan
    for _, indices in frame.loc[frame["segmentId"].notna()].groupby("segmentId", sort=True).groups.items():
        part = frame.loc[indices].sort_values("t")
        dt = part["t"].diff()
        dx = part["xSmoothM"].diff()
        dy = part["ySmoothM"].diff()
        distance = np.hypot(dx, dy)
        frame.loc[part.index, "dtSec"] = dt.to_numpy()
        frame.loc[part.index, "stepDistanceM"] = distance.to_numpy()
        frame.loc[part.index, "speedMps"] = (distance / dt.where(dt > 0)).to_numpy()
        frame.loc[part.index, "headingDeg"] = ((np.degrees(np.arctan2(dy, dx)) + 360) % 360).to_numpy()
    frame["speedAnomaly"] = frame["speedMps"] > config.max_speed_mps
    frame["usableForMovement"] = frame["usableBase"] & frame["dtSec"].gt(0) & frame["dtSec"].le(config.gap_sec) & frame["speedMps"].notna() & ~frame["speedAnomaly"]
    frame["usableForSpatialMetrics"] = frame["usableBase"] & ~frame["speedAnomaly"]
    frame["observedIntervalSec"] = np.where(frame["usableForMovement"], frame["dtSec"], 0.0)
    frame["pathStepM"] = np.where(frame["usableForMovement"], frame["stepDistanceM"], 0.0)
    return frame, estimated_fps


def build_stop_episodes(frame: pd.DataFrame, config: AnalysisConfig) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    for segment_id, part in frame.loc[frame["segmentId"].notna()].groupby("segmentId", sort=True):
        part = part.sort_values("t").copy()
        stopped = part["usableForMovement"] & part["speedMps"].lt(config.stop_speed_mps)
        runs = stopped.ne(stopped.shift(fill_value=False)).cumsum()
        for _, run in part.loc[stopped].groupby(runs[stopped], sort=True):
            duration = float(run["observedIntervalSec"].sum())
            if duration + 1e-9 < config.stop_min_sec:
                continue
            first, last = run.iloc[0], run.iloc[-1]
            rows.append({
                "episodeId": "",
                "trackId": first["id"],
                "segmentId": segment_id,
                "startSec": float(first["t"] - first["dtSec"]),
                "endSec": float(last["t"]),
                "durationSec": duration,
                "centroidXM": float(np.average(run["xSmoothM"], weights=np.maximum(run["observedIntervalSec"], 1e-6))),
                "centroidYM": float(np.average(run["ySmoothM"], weights=np.maximum(run["observedIntervalSec"], 1e-6))),
                "sampleCount": int(len(run)),
            })
    rows.sort(key=lambda item: (item["startSec"], str(item["trackId"])))
    for index, row in enumerate(rows, 1):
        row["episodeId"] = f"stop-{index:04d}"
    return pd.DataFrame(rows, columns=["episodeId", "trackId", "segmentId", "startSec", "endSec", "durationSec", "centroidXM", "centroidYM", "sampleCount"])


def build_track_summary(frame: pd.DataFrame, stops: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    stop_groups = stops.groupby("trackId") if len(stops) else None
    for track_id, part in frame.groupby("id", sort=True):
        valid = part.loc[part["usableBase"]].sort_values("t")
        movement = part.loc[part["usableForMovement"]]
        track_stops = stop_groups.get_group(track_id) if stop_groups is not None and track_id in stop_groups.groups else None
        rows.append({
            "trackId": track_id,
            "startSec": float(valid["t"].min()) if len(valid) else None,
            "endSec": float(valid["t"].max()) if len(valid) else None,
            "elapsedSpanSec": float(valid["t"].max() - valid["t"].min()) if len(valid) else 0.0,
            "observedDurationSec": float(part["observedIntervalSec"].sum()),
            "pathLengthM": float(part["pathStepM"].sum()),
            "meanSpeedMps": float(movement["speedMps"].mean()) if len(movement) else None,
            "medianSpeedMps": float(movement["speedMps"].median()) if len(movement) else None,
            "rawPointCount": int(len(part)),
            "validPointCount": int(part["usableBase"].sum()),
            "validPointRatio": float(part["usableBase"].mean()) if len(part) else 0.0,
            "segmentCount": int(part["segmentId"].dropna().nunique()),
            "stopEpisodeCount": int(len(track_stops)) if track_stops is not None else 0,
            "stopDurationSec": float(track_stops["durationSec"].sum()) if track_stops is not None else 0.0,
            "identityScore": float(part["identityScore"].dropna().mean()) if len(part["identityScore"].dropna()) else None,
            "identityLevel": _identity_mode(part["identityLevel"]),
        })
    return pd.DataFrame(rows)


def build_occupancy(frame: pd.DataFrame, duration_sec: float, bin_sec: int) -> pd.DataFrame:
    points = frame.loc[frame["usableForSpatialMetrics"], ["id", "t"]].copy()
    points["binStartSec"] = np.floor(points["t"] / bin_sec).astype(int) * bin_sec
    counts = points.drop_duplicates(["id", "binStartSec"]).groupby("binStartSec")["id"].nunique()
    upper = max(duration_sec, float(frame["t"].max()) if len(frame) else 0)
    starts = np.arange(0, math.floor(upper / bin_sec) * bin_sec + bin_sec, bin_sec, dtype=int)
    result = pd.DataFrame({"binStartSec": starts})
    result["binEndSec"] = result["binStartSec"] + bin_sec
    result["count"] = result["binStartSec"].map(counts).fillna(0).astype(int)
    return result


def density_surface(frame: pd.DataFrame, width_m: float, height_m: float, config: AnalysisConfig, kind: str) -> dict[str, Any]:
    if kind == "presence":
        points = frame.loc[frame["usableForSpatialMetrics"]].copy()
        weights = points["observedIntervalSec"].clip(lower=0).to_numpy()
    elif kind == "flow":
        points = frame.loc[frame["usableForMovement"] & frame["speedMps"].ge(config.stop_speed_mps)].copy()
        weights = points["pathStepM"].clip(lower=0).to_numpy()
    else:
        raise ValueError(f"Density kind tidak dikenal: {kind}")
    nx, ny = max(1, math.ceil(width_m / config.density_grid_m)), max(1, math.ceil(height_m / config.density_grid_m))
    x_edges, y_edges = np.linspace(0, width_m, nx + 1), np.linspace(0, height_m, ny + 1)
    raw, _, _ = np.histogram2d(points["xSmoothM"], points["ySmoothM"], bins=(x_edges, y_edges), weights=weights)
    raw = raw.T
    sigma = config.density_sigma_m / config.density_grid_m
    smoothed = gaussian_filter(raw, sigma=sigma, mode="constant")
    edge_support = gaussian_filter(np.ones_like(raw), sigma=sigma, mode="constant")
    surface = smoothed / np.maximum(edge_support, 1e-12)
    cell_area = (width_m / nx) * (height_m / ny)
    target = float(np.sum(weights))
    integral = float(surface.sum() * cell_area)
    if integral > 0:
        surface *= target / integral
    return {"surface": surface, "raw": raw, "xEdges": x_edges, "yEdges": y_edges, "points": points, "totalWeight": target, "cellAreaM2": cell_area, "kind": kind}


def _polygon_geometry(polygon: Polygon) -> dict[str, Any]:
    polygon = orient(polygon, sign=1.0)
    points = [[float(x), float(y)] for x, y in list(polygon.exterior.coords)[:-1]]
    holes = [[[float(x), float(y)] for x, y in list(ring.coords)[:-1]] for ring in polygon.interiors]
    geometry = {"type": "polygon", "points": points, "centroid": [float(polygon.centroid.x), float(polygon.centroid.y)], "areaM2": float(polygon.area)}
    if holes:
        geometry["holes"] = holes
    return geometry


def _shape_from_geometry(geometry: dict[str, Any]) -> Polygon:
    kind = geometry.get("type")
    if kind == "polygon":
        return Polygon(geometry["points"], geometry.get("holes") or None)
    if kind == "circle":
        return Point(*geometry["center"]).buffer(float(geometry["radiusM"]), resolution=32)
    if kind == "ellipse":
        center = geometry["center"]
        radii = geometry["radiiM"]
        angles = np.linspace(0, 2 * np.pi, 65)
        points = np.c_[radii[0] * np.cos(angles), radii[1] * np.sin(angles)]
        theta = np.radians(float(geometry.get("angleDeg", 0)))
        rotation = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
        points = points @ rotation.T + np.asarray(center)
        return Polygon(points)
    raise ValueError(f"Geometry area tidak didukung untuk containment: {kind}")


def extract_density_areas(density: dict[str, Any], width_m: float, height_m: float, config: AnalysisConfig, valid_ratio: float) -> list[dict[str, Any]]:
    surface = density["surface"]
    positive = surface[surface > 0]
    if not len(positive):
        return []
    threshold = max(float(np.quantile(positive, 0.50)), float(surface.max()) * 0.08)
    mask = surface >= threshold
    min_distance = max(1, round(config.peak_min_distance_m / config.density_grid_m))
    peaks = peak_local_max(surface, min_distance=min_distance, threshold_abs=threshold, labels=mask, num_peaks=config.max_areas_per_kind)
    if not len(peaks):
        return []
    markers = np.zeros_like(surface, dtype=int)
    for index, (row, column) in enumerate(peaks, 1):
        markers[row, column] = index
    labels = watershed(-surface, markers, mask=mask)
    points = density["points"]
    venue_box = box(0, 0, width_m, height_m)
    candidates: list[dict[str, Any]] = []
    for label in range(1, int(labels.max()) + 1):
        region = labels == label
        contours = find_contours(region.astype(float), 0.5)
        if not contours:
            continue
        contour = max(contours, key=len)
        polygon_points = [(float(column * config.density_grid_m), float(row * config.density_grid_m)) for row, column in contour]
        polygon = Polygon(polygon_points).buffer(0).intersection(venue_box).simplify(config.density_grid_m, preserve_topology=True)
        if polygon.is_empty:
            continue
        if polygon.geom_type == "MultiPolygon":
            polygon = max(polygon.geoms, key=lambda item: item.area)
        if polygon.area < config.min_area_m2:
            continue
        inside = contains_xy(polygon, points["xSmoothM"].to_numpy(), points["ySmoothM"].to_numpy())
        support = points.loc[inside]
        unique_visitors = int(support["id"].nunique())
        if unique_visitors < config.min_area_visitors:
            continue
        if density["kind"] == "presence":
            weight = float(support["observedIntervalSec"].sum())
            metrics = {"observedPresenceSec": weight, "uniqueVisitors": unique_visitors, "pointCount": int(len(support))}
            kind, prefix = "presence_hotspot", "presence"
        else:
            weight = float(support["pathStepM"].sum())
            metrics = {"totalPathLengthM": weight, "meanSpeedMps": float(support["speedMps"].mean()), "uniqueVisitors": unique_visitors, "pointCount": int(len(support))}
            kind, prefix = "flow_hotspot", "flow"
        candidates.append({
            "areaId": "",
            "kind": kind,
            "geometryM": _polygon_geometry(polygon),
            "timeRangeSec": {"start": float(support["t"].min()), "end": float(support["t"].max())},
            "metrics": metrics,
            "score": weight,
            "confidence": float(valid_ratio * min(1.0, unique_visitors / 5.0)),
            "confidenceBasis": "density_contour_with_unique_visitor_support",
            "limitation": "Area observasional dinamis; bukan nama tempat atau zona semantik.",
        })
    candidates.sort(key=lambda area: (-area["score"], area["geometryM"]["centroid"]))
    maximum = candidates[0]["score"] if candidates else 1.0
    for index, area in enumerate(candidates[: config.max_areas_per_kind], 1):
        area["areaId"] = f"{prefix}-{index:02d}"
        area["metrics"]["relativeIntensity"] = float(area.pop("score") / maximum) if maximum else 0.0
    return candidates[: config.max_areas_per_kind]


def extract_low_activity_areas(
    density: dict[str, Any],
    presence_density: dict[str, Any],
    width_m: float,
    height_m: float,
    config: AnalysisConfig,
    valid_ratio: float,
) -> list[dict[str, Any]]:
    """Extract low-density contours inside the observed-support envelope.

    The support envelope is deliberately derived from observed trajectory
    samples, not treated as a complete walkable-floor mask.  This prevents
    unobserved walls and furniture from being promoted as "quiet areas" while
    keeping the geometry dynamic and data-driven.
    """
    surface = density["surface"]
    if not surface.size or not np.any(presence_density["raw"] > 0):
        return []
    support_sigma = max(1.0, 0.50 / config.density_grid_m)
    support_probability = gaussian_filter((presence_density["raw"] > 0).astype(float), sigma=support_sigma, mode="constant")
    positive_support = support_probability[support_probability > 0]
    if not len(positive_support):
        return []
    support_threshold = max(0.01, float(np.quantile(positive_support, 0.20)))
    support_mask = support_probability >= support_threshold
    supported_values = surface[support_mask]
    if not len(supported_values):
        return []
    low_threshold = float(np.quantile(supported_values, 0.35))
    low_mask = support_mask & (surface <= low_threshold)
    labels = connected_components(low_mask, connectivity=2)
    venue = box(0, 0, width_m, height_m)
    x_step = width_m / surface.shape[1]
    y_step = height_m / surface.shape[0]
    presence_points = presence_density["points"]
    metric_points = density["points"]
    global_max = float(surface[support_mask].max()) or 1.0
    candidates: list[dict[str, Any]] = []
    for label_id in range(1, int(labels.max()) + 1):
        region = labels == label_id
        contours = find_contours(region.astype(float), 0.5)
        if not contours:
            continue
        contour = max(contours, key=len)
        polygon = Polygon([(float(column * x_step), float(row * y_step)) for row, column in contour]).buffer(0).intersection(venue).simplify(config.density_grid_m, preserve_topology=True)
        if polygon.is_empty:
            continue
        if polygon.geom_type == "MultiPolygon":
            polygon = max(polygon.geoms, key=lambda item: item.area)
        if polygon.area < config.min_area_m2:
            continue
        observed_inside = contains_xy(polygon, presence_points["xSmoothM"].to_numpy(), presence_points["ySmoothM"].to_numpy())
        observed_support = presence_points.loc[observed_inside]
        unique_visitors = int(observed_support["id"].nunique())
        if unique_visitors < config.min_area_visitors:
            continue
        metric_inside = contains_xy(polygon, metric_points["xSmoothM"].to_numpy(), metric_points["ySmoothM"].to_numpy())
        metric_support = metric_points.loc[metric_inside]
        region_values = surface[region]
        mean_density = float(region_values.mean()) if len(region_values) else 0.0
        relative = mean_density / global_max
        if density["kind"] == "presence":
            kind, prefix = "low_presence_area", "low-presence"
            metrics = {
                "observedPresenceSec": float(metric_support["observedIntervalSec"].sum()) if len(metric_support) else 0.0,
                "relativeIntensity": relative,
                "meanDensity": mean_density,
                "uniqueVisitors": unique_visitors,
                "pointCount": int(len(metric_support)),
                "observedSupportAreaM2": float(polygon.area),
            }
        else:
            kind, prefix = "low_flow_area", "low-flow"
            metrics = {
                "totalPathLengthM": float(metric_support["pathStepM"].sum()) if len(metric_support) else 0.0,
                "relativeIntensity": relative,
                "meanDensity": mean_density,
                "meanSpeedMps": float(metric_support["speedMps"].mean()) if len(metric_support) else 0.0,
                "uniqueVisitors": unique_visitors,
                "pointCount": int(len(metric_support)),
                "observedSupportAreaM2": float(polygon.area),
            }
        candidates.append({
            "areaId": "",
            "kind": kind,
            "geometryM": _polygon_geometry(polygon),
            "timeRangeSec": {
                "start": float(observed_support["t"].min()),
                "end": float(observed_support["t"].max()),
            },
            "metrics": metrics,
            "score": relative,
            "confidence": float(valid_ratio * min(1.0, unique_visitors / 5.0) * 0.75),
            "confidenceBasis": "low_density_contour_inside_observed_support_envelope",
            "limitation": "Kandidat aktivitas rendah hanya di observed-support envelope; belum tersedia walkable-floor mask yang memastikan seluruh venue dapat dilalui.",
        })
    candidates.sort(key=lambda area: (area["score"], area["geometryM"]["centroid"]))
    for index, area in enumerate(candidates[: config.max_areas_per_kind], 1):
        area["areaId"] = f"{prefix}-{index:02d}"
        area.pop("score", None)
    return candidates[: config.max_areas_per_kind]


def build_spatial_density_table(presence: dict[str, Any], flow: dict[str, Any], config: AnalysisConfig) -> pd.DataFrame:
    """Publish the continuous density surfaces as queryable analytical data."""
    surface = presence["surface"]
    if surface.shape != flow["surface"].shape:
        raise ValueError("Presence dan flow density harus memakai grid yang sama.")
    support_sigma = max(1.0, 0.50 / config.density_grid_m)
    support_probability = gaussian_filter((presence["raw"] > 0).astype(float), sigma=support_sigma, mode="constant")
    positive = support_probability[support_probability > 0]
    threshold = max(0.01, float(np.quantile(positive, 0.20))) if len(positive) else 1.0
    x_centers = (presence["xEdges"][:-1] + presence["xEdges"][1:]) / 2
    y_centers = (presence["yEdges"][:-1] + presence["yEdges"][1:]) / 2
    xx, yy = np.meshgrid(x_centers, y_centers)
    return pd.DataFrame({
        "cellX": np.tile(np.arange(surface.shape[1]), surface.shape[0]),
        "cellY": np.repeat(np.arange(surface.shape[0]), surface.shape[1]),
        "centerXM": xx.ravel(),
        "centerYM": yy.ravel(),
        "presenceSecPerM2": presence["surface"].ravel(),
        "flowMPerM2": flow["surface"].ravel(),
        "observedSupportProbability": support_probability.ravel(),
        "insideObservedSupport": (support_probability >= threshold).ravel(),
    })


def build_stop_clusters(stops: pd.DataFrame, width_m: float, height_m: float, valid_ratio: float) -> list[dict[str, Any]]:
    if len(stops) < 3:
        return []
    minimum = max(3, min(8, math.ceil(len(stops) * 0.02)))
    labels = HDBSCAN(min_cluster_size=minimum, min_samples=2, cluster_selection_method="leaf", copy=True).fit_predict(stops[["centroidXM", "centroidYM"]].to_numpy())
    venue = box(0, 0, width_m, height_m)
    areas: list[dict[str, Any]] = []
    for label in sorted(item for item in set(labels) if item >= 0):
        cluster = stops.loc[labels == label].copy()
        unique_visitors = int(cluster["trackId"].nunique())
        if unique_visitors < 2:
            continue
        weights = cluster["durationSec"].clip(lower=1e-6).to_numpy()
        coordinates = cluster[["centroidXM", "centroidYM"]].to_numpy()
        center = np.average(coordinates, axis=0, weights=weights)
        covariance = np.cov(coordinates.T, aweights=weights) if len(cluster) > 2 else np.eye(2) * 0.04
        eigenvalues, eigenvectors = np.linalg.eigh(np.nan_to_num(covariance, nan=0.04))
        order = np.argsort(eigenvalues)[::-1]
        radii = np.maximum(0.35, 2.0 * np.sqrt(np.maximum(eigenvalues[order], 0.01)))
        radii = np.minimum(radii, [2.0, 1.5])
        angle = math.degrees(math.atan2(eigenvectors[1, order[0]], eigenvectors[0, order[0]]))
        geometry = {"type": "ellipse", "center": [float(center[0]), float(center[1])], "radiiM": [float(radii[0]), float(radii[1])], "angleDeg": float(angle)}
        clipped = _shape_from_geometry(geometry).intersection(venue)
        if clipped.area < 0.25:
            continue
        areas.append({
            "areaId": "",
            "kind": "stop_cluster",
            "geometryM": geometry,
            "timeRangeSec": {"start": float(cluster["startSec"].min()), "end": float(cluster["endSec"].max())},
            "metrics": {"episodeCount": int(len(cluster)), "uniqueVisitors": unique_visitors, "totalDwellSec": float(cluster["durationSec"].sum()), "medianEpisodeSec": float(cluster["durationSec"].median())},
            "confidence": float(valid_ratio * min(1.0, len(cluster) / 8.0)),
            "confidenceBasis": "hdbscan_episode_support",
            "limitation": "Cluster berhenti tidak membuktikan aktivitas, antrean, atau preferensi pengunjung.",
        })
    areas.sort(key=lambda area: -area["metrics"]["totalDwellSec"])
    for index, area in enumerate(areas, 1):
        area["areaId"] = f"stop-cluster-{index:02d}"
    return areas


def resample_trajectory(frame: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    for segment_id, part in frame.loc[frame["segmentId"].notna()].groupby("segmentId", sort=True):
        part = part.sort_values("t").drop_duplicates("t")
        if len(part) < 2:
            continue
        seconds = np.arange(math.ceil(float(part["t"].min())), math.floor(float(part["t"].max())) + 1)
        if not len(seconds):
            continue
        rows.extend({
            "timeSec": int(second),
            "trackId": part.iloc[0]["id"],
            "segmentId": segment_id,
            "xM": float(np.interp(second, part["t"], part["xSmoothM"])),
            "yM": float(np.interp(second, part["t"], part["ySmoothM"])),
            "speedMps": float(np.interp(second, part["t"], part["speedMps"].fillna(0))),
            "headingDeg": float(np.interp(second, part["t"], part["headingDeg"].bfill().fillna(0))),
        } for second in seconds)
    return pd.DataFrame(rows, columns=["timeSec", "trackId", "segmentId", "xM", "yM", "speedMps", "headingDeg"])


def build_crowd_bottleneck(resampled: pd.DataFrame, frame: pd.DataFrame, width_m: float, height_m: float, valid_ratio: float) -> tuple[pd.DataFrame, list[dict[str, Any]], list[dict[str, Any]]]:
    columns = ["timeSec", "cellX", "cellY", "centerXM", "centerYM", "occupancy", "medianSpeedMps", "speedRatio", "crowded", "bottleneck", "queueLike"]
    if resampled.empty:
        return pd.DataFrame(columns=columns), [], []
    cell_m = 0.5
    sample = resampled.copy()
    sample["cellX"] = np.minimum(np.floor(sample["xM"] / cell_m).astype(int), math.ceil(width_m / cell_m) - 1)
    sample["cellY"] = np.minimum(np.floor(sample["yM"] / cell_m).astype(int), math.ceil(height_m / cell_m) - 1)
    baseline = frame.loc[frame["usableForMovement"]].groupby("id")["speedMps"].median().clip(lower=0.2)
    sample["baselineSpeedMps"] = sample["trackId"].map(baseline).fillna(0.5)
    sample["speedRatioSample"] = sample["speedMps"] / sample["baselineSpeedMps"]
    result = sample.groupby(["timeSec", "cellX", "cellY"], sort=True).agg(occupancy=("trackId", "nunique"), medianSpeedMps=("speedMps", "median"), speedRatio=("speedRatioSample", "median")).reset_index()
    result["centerXM"] = (result["cellX"] + 0.5) * cell_m
    result["centerYM"] = (result["cellY"] + 0.5) * cell_m
    crowded_threshold = max(2, int(math.ceil(result["occupancy"].quantile(0.75))))
    result["crowded"] = result["occupancy"] >= crowded_threshold
    result["bottleneck"] = result["occupancy"].ge(3) & result["speedRatio"].le(0.60)
    result["queueLike"] = result["occupancy"].ge(3) & result["medianSpeedMps"].lt(0.30)
    crowded_keys = result.loc[result["crowded"], ["timeSec", "cellX", "cellY"]]
    crowded_samples = sample.merge(crowded_keys, on=["timeSec", "cellX", "cellY"], how="inner")
    crowd_areas: list[dict[str, Any]] = []
    if len(crowded_samples) >= 5:
        minimum = max(5, min(20, math.ceil(len(crowded_samples) * 0.03)))
        crowd_labels = HDBSCAN(min_cluster_size=minimum, min_samples=3, cluster_selection_method="leaf", copy=True).fit_predict(crowded_samples[["xM", "yM"]].to_numpy())
        venue = box(0, 0, width_m, height_m)
        for label in sorted(item for item in set(crowd_labels) if item >= 0):
            cluster = crowded_samples.loc[crowd_labels == label].copy()
            visitor_count = int(cluster["trackId"].nunique())
            if visitor_count < 2:
                continue
            coordinates = cluster[["xM", "yM"]].to_numpy()
            center = np.median(coordinates, axis=0)
            covariance = np.cov(coordinates.T) if len(cluster) > 2 else np.eye(2) * 0.04
            eigenvalues, eigenvectors = np.linalg.eigh(np.nan_to_num(covariance, nan=0.04))
            order = np.argsort(eigenvalues)[::-1]
            radii = np.clip(2.0 * np.sqrt(np.maximum(eigenvalues[order], 0.02)), 0.4, 1.5)
            angle = math.degrees(math.atan2(eigenvectors[1, order[0]], eigenvectors[0, order[0]]))
            geometry = {"type": "ellipse", "center": [float(center[0]), float(center[1])], "radiiM": [float(radii[0]), float(radii[1])], "angleDeg": float(angle)}
            if _shape_from_geometry(geometry).intersection(venue).area < 0.25:
                continue
            concurrent = cluster.groupby("timeSec")["trackId"].nunique()
            crowd_areas.append({
                "areaId": "",
                "kind": "crowd_zone",
                "geometryM": geometry,
                "timeRangeSec": {"start": int(cluster["timeSec"].min()), "end": int(cluster["timeSec"].max())},
                "metrics": {"peakConcurrentTracks": int(concurrent.max()), "observedCrowdedSeconds": int(cluster["timeSec"].nunique()), "uniqueVisitors": visitor_count},
                "confidence": float(valid_ratio * min(1.0, cluster["timeSec"].nunique() / 10.0)),
                "confidenceBasis": "unique_concurrent_track_persistence",
                "limitation": "Crowd zone adalah pola okupansi lokal anonim, bukan kapasitas desain atau identitas sosial.",
            })
    crowd_areas.sort(key=lambda area: (-area["metrics"]["observedCrowdedSeconds"], -area["metrics"]["peakConcurrentTracks"]))
    for index, area in enumerate(crowd_areas[:5], 1):
        area["areaId"] = f"crowd-{index:02d}"
    crowd_areas = crowd_areas[:5]
    aggregates = result.groupby(["cellX", "cellY"], sort=True).agg(peakOccupancy=("occupancy", "max"), medianSpeedMps=("medianSpeedMps", "median"), medianSpeedRatio=("speedRatio", "median"), congestedBins=("bottleneck", "sum"), queueLikeBins=("queueLike", "sum")).reset_index()
    areas: list[dict[str, Any]] = []
    for row in aggregates.loc[aggregates["congestedBins"] >= 3].sort_values(["congestedBins", "peakOccupancy"], ascending=False).itertuples(index=False):
        center = [(int(row.cellX) + 0.5) * cell_m, (int(row.cellY) + 0.5) * cell_m]
        if any(math.dist(center, area["geometryM"]["center"]) < 0.75 for area in areas):
            continue
        areas.append({
            "areaId": f"bottleneck-{len(areas) + 1:02d}",
            "kind": "bottleneck_area",
            "geometryM": {"type": "circle", "center": [float(center[0]), float(center[1])], "radiusM": 0.75},
            "timeRangeSec": {"start": int(result.loc[(result["cellX"] == row.cellX) & (result["cellY"] == row.cellY) & result["bottleneck"], "timeSec"].min()), "end": int(result.loc[(result["cellX"] == row.cellX) & (result["cellY"] == row.cellY) & result["bottleneck"], "timeSec"].max())},
            "metrics": {"peakOccupancy": int(row.peakOccupancy), "medianSpeedMps": float(row.medianSpeedMps), "medianSpeedRatio": float(row.medianSpeedRatio), "congestedSeconds": int(row.congestedBins), "queueLikeSeconds": int(row.queueLikeBins)},
            "confidence": float(valid_ratio * min(1.0, row.congestedBins / 10.0)),
            "confidenceBasis": "persistent_density_and_relative_speed_drop",
            "limitation": "Bottleneck observasional; tidak membuktikan penyebab fisik atau antrean fasilitas.",
        })
        if len(areas) >= 5:
            break
    return result[columns], crowd_areas, areas


def _heading_delta(a: float, b: float) -> float:
    return abs((a - b + 180) % 360 - 180)


def build_group_episodes(resampled: pd.DataFrame, config: AnalysisConfig) -> tuple[pd.DataFrame, dict[str, Any]]:
    columns = ["groupEpisodeId", "memberTrackIds", "groupSize", "startSec", "endSec", "durationSec", "meanSeparationM", "confidence", "limitation"]
    if resampled.empty:
        return pd.DataFrame(columns=columns), {"groupEpisodeCount": 0, "soloObservationRatio": 1.0}
    pair_rows: list[dict[str, Any]] = []
    for time_sec, part in resampled.groupby("timeSec", sort=True):
        records = list(part.itertuples(index=False))
        for i in range(len(records)):
            for j in range(i + 1, len(records)):
                left, right = records[i], records[j]
                distance = math.hypot(left.xM - right.xM, left.yM - right.yM)
                if distance <= config.group_distance_m and abs(left.speedMps - right.speedMps) <= config.group_speed_delta_mps and _heading_delta(left.headingDeg, right.headingDeg) <= config.group_heading_deg:
                    pair_rows.append({"timeSec": int(time_sec), "left": str(left.trackId), "right": str(right.trackId), "distanceM": distance})
    pairs = pd.DataFrame(pair_rows)
    stable_edges: dict[int, list[tuple[str, str, float]]] = defaultdict(list)
    if len(pairs):
        for (left, right), part in pairs.groupby(["left", "right"], sort=True):
            part = part.sort_values("timeSec")
            run = part["timeSec"].diff().ne(1).cumsum()
            for _, sequence in part.groupby(run):
                if len(sequence) >= config.group_min_sec:
                    for row in sequence.itertuples(index=False):
                        stable_edges[int(row.timeSec)].append((left, right, float(row.distanceM)))
    observations: list[dict[str, Any]] = []
    grouped_track_seconds: set[tuple[int, str]] = set()
    for time_sec, edges in stable_edges.items():
        adjacency: dict[str, set[str]] = defaultdict(set)
        distances: dict[frozenset[str], float] = {}
        for left, right, distance in edges:
            adjacency[left].add(right); adjacency[right].add(left)
            distances[frozenset((left, right))] = distance
        seen: set[str] = set()
        for node in sorted(adjacency):
            if node in seen:
                continue
            stack, component = [node], set()
            while stack:
                current = stack.pop()
                if current in component:
                    continue
                component.add(current); stack.extend(adjacency[current] - component)
            seen.update(component)
            if len(component) < 2:
                continue
            members = tuple(sorted(component))
            component_distances = [distance for edge, distance in distances.items() if edge.issubset(component)]
            observations.append({"timeSec": time_sec, "members": members, "meanSeparationM": float(np.mean(component_distances))})
            grouped_track_seconds.update((time_sec, member) for member in members)
    obs = pd.DataFrame(observations)
    episodes: list[dict[str, Any]] = []
    if len(obs):
        for members, part in obs.groupby("members", sort=True):
            part = part.sort_values("timeSec")
            run = part["timeSec"].diff().ne(1).cumsum()
            for _, sequence in part.groupby(run):
                duration = int(sequence["timeSec"].max() - sequence["timeSec"].min() + 1)
                if duration < config.group_min_sec:
                    continue
                episodes.append({
                    "groupEpisodeId": f"group-{len(episodes) + 1:04d}",
                    "memberTrackIds": list(members),
                    "groupSize": len(members),
                    "startSec": int(sequence["timeSec"].min()),
                    "endSec": int(sequence["timeSec"].max()),
                    "durationSec": duration,
                    "meanSeparationM": float(sequence["meanSeparationM"].mean()),
                    "confidence": min(1.0, duration / 20.0),
                    "limitation": "Co-moving proxy; tidak membuktikan hubungan sosial antarorang.",
                })
    total_track_seconds = len(resampled.drop_duplicates(["timeSec", "trackId"]))
    solo_ratio = 1.0 - len(grouped_track_seconds) / max(total_track_seconds, 1)
    return pd.DataFrame(episodes, columns=columns), {"groupEpisodeCount": len(episodes), "soloObservationRatio": float(solo_ratio), "maxObservedGroupSize": max((item["groupSize"] for item in episodes), default=1)}


def _resample_route(part: pd.DataFrame, points: int) -> np.ndarray | None:
    part = part.sort_values("t")
    xy = part[["xSmoothM", "ySmoothM"]].to_numpy(dtype=float)
    if len(xy) < 2:
        return None
    distance = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(xy, axis=0), axis=1))]
    if distance[-1] <= 0:
        return None
    target = np.linspace(0, distance[-1], points)
    return np.c_[np.interp(target, distance, xy[:, 0]), np.interp(target, distance, xy[:, 1])]


def build_route_archetypes(frames: list[tuple[str, pd.DataFrame]], config: AnalysisConfig) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for job_id, frame in frames:
        for segment_id, part in frame.loc[frame["segmentId"].notna()].groupby("segmentId", sort=True):
            if float(part["pathStepM"].sum()) < config.route_min_length_m or float(part["t"].max() - part["t"].min()) < config.route_min_duration_sec:
                continue
            route = _resample_route(part, config.route_points)
            if route is not None:
                records.append({"jobId": job_id, "segmentId": str(segment_id), "trackId": str(part.iloc[0]["id"]), "route": route})
    if len(records) < 3:
        return []
    distance = np.zeros((len(records), len(records)))
    for i in range(len(records)):
        for j in range(i + 1, len(records)):
            value = float(np.mean(np.linalg.norm(records[i]["route"] - records[j]["route"], axis=1)))
            distance[i, j] = distance[j, i] = value
    labels = AgglomerativeClustering(n_clusters=None, metric="precomputed", linkage="average", distance_threshold=config.route_cluster_distance_m).fit_predict(distance)
    output: list[dict[str, Any]] = []
    for label in sorted(set(labels)):
        indices = np.where(labels == label)[0]
        if len(indices) < 3:
            continue
        local_distance = distance[np.ix_(indices, indices)]
        medoid = int(indices[int(np.argmin(local_distance.sum(axis=1)))])
        jobs = sorted({records[index]["jobId"] for index in indices})
        output.append({
            "areaId": "",
            "kind": "route_archetype",
            "geometryM": {"type": "polyline", "points": records[medoid]["route"].round(4).tolist()},
            "metrics": {"supportTracks": int(len(indices)), "supportJobs": int(len(jobs)), "jobIds": jobs, "usualAcrossJobs": len(jobs) >= 2},
            "confidence": min(1.0, len(indices) / 8.0),
            "limitation": "Pola jalur anonim; bukan kebiasaan individu yang dikenali lintas hari.",
        })
    output.sort(key=lambda item: (-item["metrics"]["supportJobs"], -item["metrics"]["supportTracks"]))
    for index, item in enumerate(output, 1):
        item["areaId"] = f"route-{index:02d}"
    return output


def load_venue_context(path: Path, fingerprint: str, width_m: float, height_m: float) -> dict[str, Any]:
    if not path.is_file():
        return {"schemaVersion": "1.0", "venueFingerprint": fingerprint, "coordinateSystem": {"unit": "meter", "widthM": width_m, "heightM": height_m}, "tables": []}
    context = _read_json(path)
    if context.get("venueFingerprint") != fingerprint:
        raise ValueError("venue_context fingerprint tidak cocok dengan floorplan aktif.")
    validate_table_context(context, width_m, height_m)
    return context


def validate_table_context(context: dict[str, Any], width_m: float, height_m: float) -> None:
    venue = box(0, 0, width_m, height_m)
    seen: list[Polygon] = []
    for table in context.get("tables") or []:
        polygon = Polygon(table.get("geometryM", {}).get("points") or [])
        if not polygon.is_valid or polygon.area < 0.1 or not venue.covers(polygon):
            raise ValueError(f"Polygon meja tidak valid atau di luar venue: {table.get('featureId')}")
        if any(polygon.equals_exact(previous, 1e-6) for previous in seen):
            raise ValueError(f"Polygon meja duplikat: {table.get('featureId')}")
        if any(polygon.intersection(previous).area > 1e-6 for previous in seen):
            raise ValueError(f"Polygon meja bertumpang tindih: {table.get('featureId')}")
        seen.append(polygon)


def build_table_areas(context: dict[str, Any], width_m: float, height_m: float) -> list[dict[str, Any]]:
    venue = box(0, 0, width_m, height_m)
    areas: list[dict[str, Any]] = []
    for table in context.get("tables") or []:
        polygon = Polygon(table["geometryM"]["points"])
        interaction = polygon.buffer(1.0).difference(polygon).intersection(venue)
        areas.append({
            "areaId": table["featureId"],
            "kind": "table",
            "label": table.get("label") or table["featureId"],
            "geometryM": _polygon_geometry(polygon),
            "interactionGeometryM": _polygon_geometry(interaction if interaction.geom_type == "Polygon" else max(interaction.geoms, key=lambda item: item.area)),
            "metrics": {"tableAreaM2": float(polygon.area), "interactionAreaM2": float(interaction.area)},
            "confidence": 1.0,
            "confidenceBasis": "manual_verified_polygon",
            "limitation": "Pemakaian dihitung dari interaction zone; kapasitas kursi tidak tersedia.",
        })
    return areas


def build_area_visits(frame: pd.DataFrame, areas: list[dict[str, Any]], minimum_sec: float = 1.0) -> pd.DataFrame:
    columns = ["visitId", "areaId", "trackId", "segmentId", "startSec", "endSec", "durationSec", "sampleCount"]
    rows: list[dict[str, Any]] = []
    spatial = frame.loc[frame["segmentId"].notna()].copy()
    table_areas = [area for area in areas if area["kind"] == "table"]
    regular_areas = [area for area in areas if area["kind"] != "table"]

    def append_sequences(part: pd.DataFrame, inside: np.ndarray, area: dict[str, Any], minimum: float) -> None:
        runs = pd.Series(inside, index=part.index).ne(pd.Series(inside, index=part.index).shift(fill_value=False)).cumsum()
        for _, sequence in part.loc[inside].groupby(runs[inside], sort=True):
            duration = float(sequence["observedIntervalSec"].sum())
            if duration < minimum:
                continue
            rows.append({"visitId": f"visit-{len(rows) + 1:06d}", "areaId": area["areaId"], "trackId": sequence.iloc[0]["id"], "segmentId": sequence.iloc[0]["segmentId"], "startSec": float(sequence["t"].min()), "endSec": float(sequence["t"].max()), "durationSec": duration, "sampleCount": int(len(sequence))})

    for area in regular_areas:
        geometry = area.get("interactionGeometryM") or area["geometryM"]
        if geometry.get("type") == "polyline":
            continue
        shape = _shape_from_geometry(geometry)
        for segment_id, part in spatial.groupby("segmentId", sort=True):
            part = part.sort_values("t").copy()
            inside = contains_xy(shape, part["xSmoothM"].to_numpy(), part["ySmoothM"].to_numpy())
            append_sequences(part, inside, area, minimum_sec)

    if table_areas:
        interaction_shapes = {area["areaId"]: _shape_from_geometry(area["interactionGeometryM"]) for area in table_areas}
        table_shapes = {area["areaId"]: _shape_from_geometry(area["geometryM"]) for area in table_areas}
        for _, part in spatial.groupby("segmentId", sort=True):
            part = part.sort_values("t").copy()
            xs, ys = part["xSmoothM"].to_numpy(), part["ySmoothM"].to_numpy()
            assignments = np.full(len(part), None, dtype=object)
            best_distance = np.full(len(part), np.inf)
            for area in table_areas:
                area_id = area["areaId"]
                candidates = contains_xy(interaction_shapes[area_id], xs, ys)
                for position in np.flatnonzero(candidates):
                    distance = Point(float(xs[position]), float(ys[position])).distance(table_shapes[area_id])
                    if distance < best_distance[position]:
                        assignments[position] = area_id
                        best_distance[position] = distance
            for area in table_areas:
                append_sequences(part, assignments == area["areaId"], area, 3.0)
    return pd.DataFrame(rows, columns=columns)


def _enrich_area_visit_metrics(areas: list[dict[str, Any]], visits: pd.DataFrame) -> None:
    for area in areas:
        part = visits.loc[visits["areaId"] == area["areaId"]] if len(visits) else visits
        area["metrics"].update({
            "visitCount": int(len(part)),
            "uniqueVisitors": int(part["trackId"].nunique()) if len(part) else 0,
            "meanVisitDurationSec": float(part["durationSec"].mean()) if len(part) else 0.0,
            "medianVisitDurationSec": float(part["durationSec"].median()) if len(part) else 0.0,
            "p95VisitDurationSec": float(part["durationSec"].quantile(0.95)) if len(part) else 0.0,
        })


def build_capability_catalog(has_tables: bool, has_routes: bool, has_cross_job_routes: bool, has_bottlenecks: bool, has_groups: bool) -> dict[str, Any]:
    def item(status: str, required: list[str], limitation: str) -> dict[str, Any]:
        return {"status": status, "requiredData": required, "limitation": limitation}
    return {
        "schemaVersion": "1.0",
        "capabilities": {
            "peak_occupancy": item("supported", [], "Occupancy adalah anonymous global track per bin waktu."),
            "most_traversed_area": item("supported", [], "Area flow bersifat observasional."),
            "most_occupied_area": item("supported", [], "Area presence bersifat observasional."),
            "low_activity_area": item("partially_supported", ["walkable-floor mask untuk cakupan venue penuh"], "Low-flow/low-presence hanya dicari di observed-support envelope."),
            "dwell_area": item("supported", [], "Dwell tidak menjembatani gap tracking."),
            "bottleneck": item("supported", [], "Bottleneck observasional, bukan diagnosis penyebab fisik; hasil dapat berupa tidak ada kandidat yang memenuhi threshold."),
            "group_behavior": item("partially_supported" if has_groups else "unsupported", [], "Co-moving proxy tidak membuktikan hubungan sosial."),
            "usual_route": item("supported" if has_cross_job_routes else ("partially_supported" if has_routes else "unsupported"), ["minimal dua job venue-compatible"] if not has_cross_job_routes else [], "Route adalah pola anonim, bukan kebiasaan individu."),
            "favorite_area": item("partially_supported", [], "Hanya most-used/longest-dwell; preferensi tidak dapat disimpulkan."),
            "table_effectiveness": item("supported" if has_tables else "unsupported", [] if has_tables else ["polygon meja manual"], "Kapasitas kursi tidak tersedia."),
            "board_game_table": item("partially_supported" if has_tables else "unsupported", [] if has_tables else ["polygon meja manual"], "Kandidat berdasarkan area meja, crowd, flow, dan dwell; bukan kapasitas kursi."),
            "display_area": item("partially_supported", ["visibility/line-of-sight untuk validasi penuh"], "Kandidat hanya berdasarkan exposure flow."),
            "chair_capacity": item("unsupported", ["jumlah dan kapasitas kursi"], "Peak occupancy tersedia, kecukupan kursi tidak dapat dinilai."),
            "queue_facility": item("partially_supported", ["facility anchor untuk identifikasi fasilitas"], "Hanya queue-like/bottleneck observasional."),
            "data_quality": item("supported", [], "QC tidak mengoreksi koordinat secara otomatis."),
        },
    }


def build_evidence_cards(job_id: str, summary: dict[str, Any], areas: list[dict[str, Any]], capabilities: dict[str, Any]) -> list[dict[str, Any]]:
    cards: list[dict[str, Any]] = []
    def add(question_types: list[str], statement: str, metrics: dict[str, Any], confidence: float, refs: list[str], area: dict[str, Any] | None = None, limitation: str | None = None) -> None:
        cards.append({"cardId": f"{job_id}-v2-evidence-{len(cards) + 1:04d}", "jobId": job_id, "questionTypes": question_types, "statement": statement, "metrics": metrics, "areaId": area.get("areaId") if area else None, "geometryM": area.get("geometryM") if area else None, "confidence": confidence, "evidenceRefs": refs, "limitation": limitation or (area.get("limitation") if area else None)})
    occupancy = summary["occupancy"]
    add(["peak_occupancy", "occupancy", "peak_time"], f"Puncak okupansi adalah {occupancy['peakCount']} track pada detik {occupancy['peakBinStartSec']:.0f}–{occupancy['peakBinEndSec']:.0f}.", occupancy, summary["quality"]["validPointRatio"], ["occupancy_timeseries.parquet"])
    add(["dwell_area", "dwell", "duration"], f"Median durasi teramati per track adalah {summary['dwell']['medianObservedDurationSec']:.1f} detik.", summary["dwell"], summary["quality"]["validPointRatio"], ["track_summary.parquet", "area_visits.parquet"], limitation="Durasi hanya menjumlah interval valid dan tidak menjembatani gap lebih dari satu detik.")
    add(["group_behavior", "solo", "group_size"], f"Rasio observasi solo adalah {summary['groups']['soloObservationRatio']:.1%}; group terbesar yang teramati berisi {summary['groups']['maxObservedGroupSize']} track.", summary["groups"], summary["quality"]["validPointRatio"], ["group_episodes.parquet"], limitation="Co-moving proxy tidak membuktikan hubungan sosial.")
    for area in areas:
        center = area["geometryM"].get("centroid") or area["geometryM"].get("center")
        if area["kind"] == "presence_hotspot": types, label = ["most_occupied_area", "presence", "favorite_area"], "Kehadiran tinggi"
        elif area["kind"] == "low_presence_area": types, label = ["low_presence", "quiet_area", "least_occupied_area"], "Kandidat kehadiran rendah"
        elif area["kind"] == "crowd_zone": types, label = ["most_occupied_area", "crowd_zone", "local_occupancy"], "Okupansi lokal bersamaan tinggi"
        elif area["kind"] == "flow_hotspot": types, label = ["most_traversed_area", "flow", "display_area"], "Arus pergerakan tinggi"
        elif area["kind"] == "low_flow_area": types, label = ["low_flow", "quiet_area", "least_traversed_area"], "Kandidat arus pergerakan rendah"
        elif area["kind"] == "stop_cluster": types, label = ["dwell_area", "longest_stop_area", "favorite_area"], "Akumulasi berhenti"
        elif area["kind"] == "bottleneck_area": types, label = ["bottleneck", "queue_facility"], "Bottleneck observasional"
        elif area["kind"] == "route_archetype": types, label = ["usual_route", "movement_pattern"], "Route archetype"
        elif area["kind"] == "table": types, label = ["table_effectiveness", "board_game_table"], "Meja teranotasi"
        else: continue
        coordinate_text = f" di sekitar ({center[0]:.2f} m, {center[1]:.2f} m)" if center else ""
        add(types, f"{label}{coordinate_text} dengan area ID {area['areaId']}.", area["metrics"], float(area.get("confidence", 0)), ["spatial_areas.json", "area_visits.parquet"], area=area)
    quality = summary["quality"]
    add(["data_quality", "limitations"], f"{quality['outOfVenueCount']} dari {quality['rawObservationCount']} observasi berada di luar venue dan tidak dipakai untuk metrik spasial.", quality, 1.0, ["manifest.json", "trajectory_enriched.parquet"])
    if not any(area["kind"] == "bottleneck_area" for area in areas):
        add(["bottleneck"], "Tidak ada kandidat bottleneck yang memenuhi threshold persistence, density, dan penurunan speed pada job aktif.", {"candidateCount": 0}, quality["validPointRatio"], ["crowd_bottleneck_timeseries.parquet"], limitation="Tidak ditemukannya kandidat bukan bukti bahwa hambatan tidak pernah terjadi di luar periode observasi.")
    for intent, capability in capabilities["capabilities"].items():
        if capability["status"] == "unsupported":
            add([intent], f"Capability {intent} belum didukung oleh data aktif.", {"supportLevel": "unsupported", "requiredData": capability["requiredData"]}, 1.0, ["capability_catalog.json"], limitation=capability["limitation"])
    return cards


def _draw_geometry(ax: Any, geometry: dict[str, Any], color: str, label: str | None = None, alpha: float = 0.25) -> None:
    kind = geometry.get("type")
    if kind == "polygon":
        patch = MplPolygon(np.asarray(geometry["points"]), closed=True, facecolor=color, edgecolor=color, linewidth=2, alpha=alpha)
        ax.add_patch(patch)
        center = geometry.get("centroid") or list(Polygon(geometry["points"]).centroid.coords)[0]
    elif kind == "circle":
        center = geometry["center"]
        patch = plt.Circle(center, geometry["radiusM"], facecolor=color, edgecolor=color, linewidth=2, alpha=alpha)
        ax.add_patch(patch)
    elif kind == "ellipse":
        center = geometry["center"]
        patch = Ellipse(center, width=2 * geometry["radiiM"][0], height=2 * geometry["radiiM"][1], angle=geometry.get("angleDeg", 0), facecolor=color, edgecolor=color, linewidth=2, alpha=alpha)
        ax.add_patch(patch)
    elif kind == "polyline":
        points = np.asarray(geometry["points"])
        ax.plot(points[:, 0], points[:, 1], color=color, linewidth=3, alpha=0.85)
        center = points[len(points) // 2]
    else:
        return
    if label:
        ax.text(center[0], center[1], label, color="white", fontsize=8, ha="center", va="center", bbox={"boxstyle": "round", "facecolor": color, "alpha": 0.9, "edgecolor": "white"})


def _floorplan_axes(ax: Any, floorplan_path: Path | None, width_m: float, height_m: float) -> None:
    if floorplan_path and floorplan_path.is_file():
        ax.imshow(plt.imread(floorplan_path), origin="upper", extent=(0, width_m, height_m, 0), aspect="equal")
    ax.set(xlim=(0, width_m), ylim=(height_m, 0), aspect="equal", xlabel="x (m)", ylabel="y (m)")


def _density_mass_levels(surface: np.ndarray) -> tuple[list[float], dict[float, str]]:
    values = np.asarray(surface, dtype=float).ravel()
    values = values[np.isfinite(values) & (values > 0)]
    if not len(values) or float(values.sum()) <= 0:
        return [], {}
    descending = np.sort(values)[::-1]
    cumulative = np.cumsum(descending) / descending.sum()
    thresholds: list[tuple[float, str]] = []
    for mass, label in ((0.90, "P90"), (0.75, "P75"), (0.50, "P50")):
        index = min(int(np.searchsorted(cumulative, mass, side="left")), len(descending) - 1)
        thresholds.append((float(descending[index]), label))
    unique: dict[float, str] = {}
    for value, label in thresholds:
        unique[value] = label
    levels = sorted(unique)
    return levels, {value: unique[value] for value in levels}


def save_figures(directory: Path, frame: pd.DataFrame, occupancy: pd.DataFrame, stops: pd.DataFrame, crowd: pd.DataFrame, groups: pd.DataFrame, areas: list[dict[str, Any]], presence_density: dict[str, Any], floorplan_path: Path | None, width_m: float, height_m: float) -> list[str]:
    directory.mkdir(parents=True, exist_ok=True)
    artifacts: list[str] = []
    surface = presence_density["surface"]
    positive = surface[surface > 0]
    low = max(float(np.quantile(positive, 0.05)) if len(positive) else 0, (float(np.quantile(positive, 0.99)) if len(positive) else 0) * 0.01)
    high = float(np.quantile(positive, 0.99)) if len(positive) else 1
    fade_end = max(low * 4.0, float(np.quantile(positive, 0.25)) if len(positive) else low + 1e-9)
    visual_alpha = np.clip((surface - low * 0.5) / max(fade_end - low * 0.5, 1e-9), 0.0, 1.0)
    visual_alpha = gaussian_filter(visual_alpha, sigma=1.0, mode="nearest")
    extent = (0, width_m, height_m, 0)
    for name, with_floorplan in (("presence_density.png", False), ("floorplan_presence_density.png", True)):
        fig, ax = plt.subplots(figsize=(11, 8))
        if with_floorplan:
            _floorplan_axes(ax, floorplan_path, width_m, height_m)
        alpha = visual_alpha * (0.68 if with_floorplan else 1.0)
        image = ax.imshow(surface, origin="upper", extent=extent, cmap="turbo", interpolation="bicubic", alpha=alpha, vmin=low, vmax=max(high, low + 1e-9))
        if len(positive):
            levels, labels = _density_mass_levels(surface)
            if levels:
                xs = np.linspace(0, width_m, surface.shape[1]); ys = np.linspace(0, height_m, surface.shape[0])
                contours = ax.contour(xs, ys, surface, levels=levels, colors="white" if with_floorplan else "black", linewidths=0.9, alpha=0.8)
                ax.clabel(contours, fmt=labels, fontsize=7, inline=True)
        fig.colorbar(image, ax=ax, label="estimated presence seconds / m²")
        ax.set(title="Continuous time-weighted presence density", xlim=(0, width_m), ylim=(height_m, 0), xlabel="x (m)", ylabel="y (m)", aspect="equal")
        fig.tight_layout(); fig.savefig(directory / name, dpi=180); plt.close(fig); artifacts.append(f"figures/{name}")
    fig, ax = plt.subplots(figsize=(11, 8)); _floorplan_axes(ax, floorplan_path, width_m, height_m)
    colors = {"presence_hotspot": "#00a6fb", "low_presence_area": "#90e0ef", "crowd_zone": "#00b4d8", "flow_hotspot": "#ff7b00", "low_flow_area": "#ffbf69", "stop_cluster": "#8338ec", "bottleneck_area": "#d00000", "table": "#2a9d8f"}
    for area in areas:
        if area["kind"] != "route_archetype":
            _draw_geometry(ax, area["geometryM"], colors.get(area["kind"], "#555555"), area["areaId"])
    ax.set_title("Dynamic observational areas"); fig.tight_layout(); fig.savefig(directory / "dynamic_areas_floorplan.png", dpi=180); plt.close(fig); artifacts.append("figures/dynamic_areas_floorplan.png")
    fig, ax = plt.subplots(figsize=(10, 4)); ax.step(occupancy["binStartSec"], occupancy["count"], where="post"); ax.set(title="Occupancy per 10 detik", xlabel="detik", ylabel="global track"); fig.tight_layout(); fig.savefig(directory / "occupancy_chart.png", dpi=160); plt.close(fig); artifacts.append("figures/occupancy_chart.png")
    fig, ax = plt.subplots(figsize=(11, 8)); _floorplan_axes(ax, floorplan_path, width_m, height_m)
    for area in areas:
        if area["kind"] == "bottleneck_area": _draw_geometry(ax, area["geometryM"], "#d00000", area["areaId"], 0.35)
    if not any(area["kind"] == "bottleneck_area" for area in areas):
        ax.text(0.5, 0.03, "Tidak ada kandidat yang memenuhi threshold bottleneck", transform=ax.transAxes, ha="center", bbox={"boxstyle": "round", "facecolor": "white", "alpha": 0.9})
    ax.set_title("Observed bottleneck candidates"); fig.tight_layout(); fig.savefig(directory / "bottleneck_map.png", dpi=180); plt.close(fig); artifacts.append("figures/bottleneck_map.png")
    fig, ax = plt.subplots(figsize=(11, 8)); _floorplan_axes(ax, floorplan_path, width_m, height_m)
    for area in areas:
        if area["kind"] == "route_archetype": _draw_geometry(ax, area["geometryM"], "#0081a7", area["areaId"], 0.8)
    if not any(area["kind"] == "route_archetype" for area in areas):
        ax.text(0.5, 0.03, "Belum ada route archetype dengan dukungan minimum", transform=ax.transAxes, ha="center", bbox={"boxstyle": "round", "facecolor": "white", "alpha": 0.9})
    ax.set_title("Route archetypes"); fig.tight_layout(); fig.savefig(directory / "route_archetypes.png", dpi=180); plt.close(fig); artifacts.append("figures/route_archetypes.png")
    fig, ax = plt.subplots(figsize=(11, 8)); _floorplan_axes(ax, floorplan_path, width_m, height_m)
    if len(stops):
        sizes = np.clip(stops["durationSec"].to_numpy() * 4.0, 12, 240)
        scatter = ax.scatter(stops["centroidXM"], stops["centroidYM"], s=sizes, c=stops["durationSec"], cmap="magma", alpha=0.58, edgecolors="white", linewidths=0.3)
        fig.colorbar(scatter, ax=ax, label="stop duration (s)")
    else:
        ax.text(0.5, 0.5, "Tidak ada stop episode", transform=ax.transAxes, ha="center")
    ax.set_title("Stop episodes (marker size = duration)"); fig.tight_layout(); fig.savefig(directory / "stop_map.png", dpi=180); plt.close(fig); artifacts.append("figures/stop_map.png")
    fig, ax = plt.subplots(figsize=(9, 4))
    speeds = frame.loc[frame["usableForMovement"], "speedMps"].dropna()
    if len(speeds): ax.hist(speeds, bins=40, color="#457b9d", alpha=0.85)
    else: ax.text(0.5, 0.5, "Tidak ada speed valid", transform=ax.transAxes, ha="center")
    ax.set(title="Distribusi speed analitik", xlabel="m/s", ylabel="observations"); fig.tight_layout(); fig.savefig(directory / "speed_distribution.png", dpi=160); plt.close(fig); artifacts.append("figures/speed_distribution.png")
    fig, ax = plt.subplots(figsize=(9, 4))
    if len(groups):
        labels = groups["groupEpisodeId"].astype(str)
        ax.bar(labels, groups["durationSec"], color="#6a4c93")
        ax.tick_params(axis="x", rotation=45)
        ax.set_ylabel("duration (s)")
    else:
        ax.text(0.5, 0.5, "Tidak ada co-moving episode stabil", transform=ax.transAxes, ha="center")
    ax.set_title("Co-moving group proxy episodes"); fig.tight_layout(); fig.savefig(directory / "group_episodes.png", dpi=160); plt.close(fig); artifacts.append("figures/group_episodes.png")
    table_areas = [area for area in areas if area["kind"] == "table"]
    if table_areas:
        fig, ax = plt.subplots(figsize=(11, 8)); _floorplan_axes(ax, floorplan_path, width_m, height_m)
        for area in table_areas:
            _draw_geometry(ax, area["interactionGeometryM"], "#80ed99", f"{area['areaId']} interaction", 0.14)
            _draw_geometry(ax, area["geometryM"], "#2a9d8f", area["areaId"], 0.45)
        ax.set_title("Manual table polygons and 1 m interaction zones"); fig.tight_layout(); fig.savefig(directory / "table_annotation.png", dpi=180); plt.close(fig); artifacts.append("figures/table_annotation.png")
    qc = {"valid": int(frame["usableBase"].sum()), "out of venue": int((frame["finiteObservation"] & ~frame["inVenue"]).sum()), "non-finite": int((~frame["finiteObservation"]).sum()), "duplicate": int(frame["duplicateObservation"].sum()), "speed anomaly": int(frame["speedAnomaly"].sum())}
    fig, ax = plt.subplots(figsize=(9, 4)); ax.bar(qc.keys(), qc.values()); ax.tick_params(axis="x", rotation=20); ax.set(title="Quality control", ylabel="observations"); fig.tight_layout(); fig.savefig(directory / "qc_plot.png", dpi=160); plt.close(fig); artifacts.append("figures/qc_plot.png")
    return artifacts


def _compatible_history(config: AnalysisConfig, active_id: str, fingerprint: str) -> list[tuple[str, pd.DataFrame]]:
    history: list[tuple[str, pd.DataFrame]] = []
    for row in discover_jobs(config.workdir).itertuples(index=False):
        if not row.trajectoryAvailable:
            continue
        directory = config.workdir / str(row.jobId)
        job = _read_json(directory / "job.json")
        venue = job.get("venue") or {}
        path_value = venue.get("floorPlanPath")
        floorplan = Path(path_value).expanduser() if path_value else None
        if venue_fingerprint(floorplan, float(venue.get("widthM", 0)), float(venue.get("heightM", 0))) != fingerprint:
            continue
        raw = pd.read_parquet(directory / "trajectories.parquet")
        cameras = job.get("cameras") or []
        start = min((float(camera.get("startSec") or 0) for camera in cameras), default=0.0)
        prepared, _ = prepare_trajectory(raw, float(venue["widthM"]), float(venue["heightM"]), start, config)
        history.append((str(row.jobId), prepared))
    return history


def run_analysis(config: AnalysisConfig | None = None) -> AnalysisResult:
    config = config or AnalysisConfig.default()
    job_id = _select_job(config)
    job_dir = config.workdir / job_id
    job_path, result_path, trajectory_path = job_dir / "job.json", job_dir / "result.json", job_dir / "trajectories.parquet"
    job, source_result = _read_json(job_path), _read_json(result_path)
    raw = pd.read_parquet(trajectory_path)
    venue = job.get("venue") or {}
    width_m, height_m = float(venue.get("widthM", 0)), float(venue.get("heightM", 0))
    if width_m <= 0 or height_m <= 0:
        raise ValueError("Dimensi venue harus positif.")
    floorplan_value = venue.get("floorPlanPath")
    floorplan_path = Path(floorplan_value).expanduser() if floorplan_value else None
    fingerprint = venue_fingerprint(floorplan_path, width_m, height_m)
    cameras = job.get("cameras") or []
    camera_start = min((float(camera.get("startSec") or 0) for camera in cameras), default=0.0)
    duration = max((float(camera.get("durationSec") or 0) for camera in cameras), default=float(raw["t"].max()))
    trajectory, estimated_fps = prepare_trajectory(raw, width_m, height_m, camera_start, config)
    expected = (source_result.get("identityQuality") or {}).get("globalIds")
    if expected is not None and int(trajectory["id"].nunique()) != int(expected):
        raise AssertionError("Jumlah global track berbeda dari result.json.")
    stops = build_stop_episodes(trajectory, config)
    tracks = build_track_summary(trajectory, stops)
    occupancy = build_occupancy(trajectory, duration, config.occupancy_bin_sec)
    valid_ratio = float(trajectory["usableBase"].mean()) if len(trajectory) else 0.0
    presence_density = density_surface(trajectory, width_m, height_m, config, "presence")
    flow_density = density_surface(trajectory, width_m, height_m, config, "flow")
    presence_areas = extract_density_areas(presence_density, width_m, height_m, config, valid_ratio)
    flow_areas = extract_density_areas(flow_density, width_m, height_m, config, valid_ratio)
    low_presence_areas = extract_low_activity_areas(presence_density, presence_density, width_m, height_m, config, valid_ratio)
    low_flow_areas = extract_low_activity_areas(flow_density, presence_density, width_m, height_m, config, valid_ratio)
    density_table = build_spatial_density_table(presence_density, flow_density, config)
    stop_areas = build_stop_clusters(stops, width_m, height_m, valid_ratio)
    resampled = resample_trajectory(trajectory)
    crowd, crowd_areas, bottleneck_areas = build_crowd_bottleneck(resampled, trajectory, width_m, height_m, valid_ratio)
    groups, group_summary = build_group_episodes(resampled, config)
    history = _compatible_history(config, job_id, fingerprint)
    routes = build_route_archetypes(history, config)
    context_path = config.backend_root / "notebooks" / "venue_context" / f"{fingerprint}.json"
    context = load_venue_context(context_path, fingerprint, width_m, height_m)
    table_areas = build_table_areas(context, width_m, height_m)
    areas = presence_areas + low_presence_areas + crowd_areas + flow_areas + low_flow_areas + stop_areas + bottleneck_areas + routes + table_areas
    visits = build_area_visits(trajectory, [area for area in areas if area["kind"] != "route_archetype"])
    _enrich_area_visit_metrics(areas, visits)
    peak = occupancy.sort_values(["count", "binStartSec"], ascending=[False, True]).iloc[0]
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "jobId": job_id,
        "venueFingerprint": fingerprint,
        "trackCount": int(trajectory["id"].nunique()),
        "quality": {"rawObservationCount": int(len(trajectory)), "validObservationCount": int(trajectory["usableBase"].sum()), "validPointRatio": valid_ratio, "outOfVenueCount": int((trajectory["finiteObservation"] & ~trajectory["inVenue"]).sum()), "nonFiniteCount": int((~trajectory["finiteObservation"]).sum()), "duplicateCount": int(trajectory["duplicateObservation"].sum()), "speedAnomalyCount": int(trajectory["speedAnomaly"].sum()), "estimatedSamplingFps": estimated_fps, "calibrationWarnings": (source_result.get("identityQuality") or {}).get("calibrationWarnings") or []},
        "occupancy": {"binSeconds": config.occupancy_bin_sec, "meanCount": float(occupancy["count"].mean()), "peakCount": int(peak["count"]), "peakBinStartSec": float(peak["binStartSec"]), "peakBinEndSec": float(peak["binEndSec"])},
        "dwell": {"meanObservedDurationSec": float(tracks["observedDurationSec"].mean()), "medianObservedDurationSec": float(tracks["observedDurationSec"].median()), "stopEpisodeCount": int(len(stops)), "totalStopDurationSec": float(stops["durationSec"].sum()) if len(stops) else 0.0},
        "movement": {"totalPathLengthM": float(tracks["pathLengthM"].sum()), "meanTrackPathLengthM": float(tracks["pathLengthM"].mean()), "presenceAreaCount": len(presence_areas), "lowPresenceAreaCount": len(low_presence_areas), "crowdAreaCount": len(crowd_areas), "flowAreaCount": len(flow_areas), "lowFlowAreaCount": len(low_flow_areas), "bottleneckAreaCount": len(bottleneck_areas), "routeArchetypeCount": len(routes)},
        "groups": group_summary,
        "tables": {"annotationAvailable": bool(table_areas), "tableCount": len(table_areas)},
        "history": {"compatibleJobIds": [item[0] for item in history], "crossJobRouteAvailable": any(route["metrics"]["usualAcrossJobs"] for route in routes)},
    }
    capabilities = build_capability_catalog(
        bool(table_areas),
        bool(routes),
        summary["history"]["crossJobRouteAvailable"],
        bool(bottleneck_areas),
        not groups.empty,
    )
    evidence = build_evidence_cards(job_id, summary, areas, capabilities)
    output_job = config.output_root / job_id
    output_dir = output_job / "explanatory-v2"
    staging = output_job / ".explanatory-v2.build"
    backup = output_job / ".explanatory-v2.previous"
    output_job.mkdir(parents=True, exist_ok=True)
    for path in (staging, backup):
        if path.exists(): shutil.rmtree(path)
    staging.mkdir(parents=True)
    trajectory.to_parquet(staging / "trajectory_enriched.parquet", index=False)
    tracks.to_parquet(staging / "track_summary.parquet", index=False)
    occupancy.to_parquet(staging / "occupancy_timeseries.parquet", index=False)
    stops.to_parquet(staging / "stop_episodes.parquet", index=False)
    visits.to_parquet(staging / "area_visits.parquet", index=False)
    crowd.to_parquet(staging / "crowd_bottleneck_timeseries.parquet", index=False)
    groups.to_parquet(staging / "group_episodes.parquet", index=False)
    density_table.to_parquet(staging / "spatial_density_surface.parquet", index=False)
    table_visits = visits.loc[visits["areaId"].isin([area["areaId"] for area in table_areas])] if len(visits) else visits.copy()
    if table_areas: table_visits.to_parquet(staging / "table_usage.parquet", index=False)
    _write_json(staging / "summary.json", summary)
    _write_json(staging / "spatial_areas.json", {"schemaVersion": SCHEMA_VERSION, "jobId": job_id, "coordinateSystem": {"type": "local_metric", "unit": "meter", "orientation": "x_right_y_down", "venueWidthM": width_m, "venueHeightM": height_m}, "areas": areas})
    _write_json(staging / "route_archetypes.json", {"schemaVersion": SCHEMA_VERSION, "jobId": job_id, "routes": routes})
    _write_json(staging / "capability_catalog.json", capabilities)
    with (staging / "evidence_cards.jsonl").open("w", encoding="utf-8") as handle:
        for card in evidence: handle.write(json.dumps(_native(card), ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n")
    figure_files = save_figures(staging / "figures", trajectory, occupancy, stops, crowd, groups, areas, presence_density, floorplan_path, width_m, height_m)
    report = f"""# Explanatory Analysis v2 — Job {job_id}

- Venue fingerprint: `{fingerprint}`
- Global track: {summary['trackCount']}
- Observasi valid: {summary['quality']['validObservationCount']} / {summary['quality']['rawObservationCount']} ({summary['quality']['validPointRatio']:.1%})
- Peak occupancy: {summary['occupancy']['peakCount']} track pada {summary['occupancy']['peakBinStartSec']:.0f}–{summary['occupancy']['peakBinEndSec']:.0f} detik
- Dynamic area: {len(areas)}
- Presence hotspot: {len(presence_areas)}; low-presence candidate: {len(low_presence_areas)}; crowd zone: {len(crowd_areas)}; flow hotspot: {len(flow_areas)}; low-flow candidate: {len(low_flow_areas)}; stop cluster: {len(stop_areas)}; bottleneck: {len(bottleneck_areas)}
- Route archetype: {len(routes)}; co-moving episode: {len(groups)}
- Annotation meja: {'tersedia' if table_areas else 'belum tersedia'}

## Interpretasi aman

Area pada package ini bersifat observasional dan anonim. Co-moving tidak membuktikan hubungan sosial, stop tidak membuktikan aktivitas atau preferensi, dan queue-like tidak boleh diberi nama fasilitas tanpa facility anchor. Koordinat invalid atau di luar venue dilaporkan tetapi tidak dipakai untuk metrik spasial.
"""
    (staging / "report.md").write_text(report, encoding="utf-8")
    file_names = ["summary.json", "report.md", "spatial_areas.json", "route_archetypes.json", "capability_catalog.json", "evidence_cards.jsonl", "trajectory_enriched.parquet", "track_summary.parquet", "occupancy_timeseries.parquet", "stop_episodes.parquet", "area_visits.parquet", "crowd_bottleneck_timeseries.parquet", "group_episodes.parquet", "spatial_density_surface.parquet"] + (["table_usage.parquet"] if table_areas else []) + figure_files
    manifest = {"schemaVersion": SCHEMA_VERSION, "jobId": job_id, "venue": venue, "venueFingerprint": fingerprint, "coordinateSystem": {"type": "local_metric", "unit": "meter", "orientation": "x_right_y_down", "widthM": width_m, "heightM": height_m}, "floorplan": {"sourcePath": str(floorplan_path) if floorplan_path else None, "available": bool(floorplan_path and floorplan_path.is_file())}, "timeline": {"durationSec": duration, "videoStartSec": camera_start}, "config": _native(asdict(config) | {"backend_root": str(config.backend_root), "workdir": str(config.workdir), "output_root": str(config.output_root)}), "quality": summary["quality"], "inputs": {"jobJson": str(job_path), "resultJson": str(result_path), "trajectoriesParquet": str(trajectory_path), "sha256": {"jobJson": _sha256(job_path), "resultJson": _sha256(result_path), "trajectoriesParquet": _sha256(trajectory_path)}}, "files": ["manifest.json"] + file_names, "limitations": ["Area observasional bukan label aktivitas atau preferensi.", "Co-moving group bukan hubungan sosial.", "Kapasitas kursi tidak tersedia.", "Koordinat invalid tidak di-clamp."]}
    _write_json(staging / "manifest.json", manifest)
    try:
        if output_dir.exists(): output_dir.rename(backup)
        staging.rename(output_dir)
    except Exception:
        if not output_dir.exists() and backup.exists(): backup.rename(output_dir)
        raise
    finally:
        if backup.exists(): shutil.rmtree(backup)
    latest = {"schemaVersion": "1.0", "jobId": job_id, "packageVersion": SCHEMA_VERSION, "packagePath": str(output_dir), "venueFingerprint": fingerprint}
    latest_tmp = config.output_root / ".latest.tmp"
    _write_json(latest_tmp, latest); latest_tmp.replace(config.output_root / "latest.json")
    return AnalysisResult(job_id, output_dir, fingerprint, summary, floorplan_path, context_path, [item[0] for item in history])


def create_table_annotation_widget(result: AnalysisResult, rebuild: bool = True):
    """Return an embedded notebook editor for optional table polygons.

    This deliberately uses ipympl, already supported by the VS Code/Cursor
    notebook renderer, rather than a third-party browser widget.  Raw
    ``button_press_event`` handling is more portable there than
    ``PolygonSelector``: every left-click inside the floorplan adds one point.
    """
    import ipywidgets as widgets
    from IPython.display import display

    manifest = _read_json(result.output_dir / "manifest.json")
    width_m, height_m = float(manifest["coordinateSystem"]["widthM"]), float(manifest["coordinateSystem"]["heightM"])
    context = load_venue_context(result.context_path, result.venue_fingerprint, width_m, height_m)
    tables = list(context.get("tables") or [])
    pending: list[list[float]] = []
    figure, axis = plt.subplots(figsize=(10, 7))
    _floorplan_axes(axis, result.floorplan_path, width_m, height_m)
    patches: list[Any] = []
    pending_artists: list[Any] = []

    def redraw() -> None:
        nonlocal patches, pending_artists
        for artist in [*patches, *pending_artists]:
            artist.remove()
        patches = []
        pending_artists = []
        for table in tables:
            patch = MplPolygon(np.asarray(table["geometryM"]["points"]), closed=True, facecolor="#2a9d8f", edgecolor="#006d77", alpha=0.35)
            axis.add_patch(patch)
            patches.append(patch)
            center = np.asarray(table["geometryM"]["points"], dtype=float).mean(axis=0)
            label_artist = axis.text(float(center[0]), float(center[1]), table.get("label") or table["featureId"], color="#003f45", fontsize=9, ha="center", va="center", weight="bold")
            patches.append(label_artist)
        if pending:
            array = np.asarray(pending, dtype=float)
            (line,) = axis.plot(array[:, 0], array[:, 1], "-o", color="#1976d2", linewidth=2.8, markersize=7, zorder=20)
            pending_artists.append(line)
            for index, point in enumerate(array, start=1):
                pending_artists.append(axis.text(float(point[0]), float(point[1]), str(index), color="#0d47a1", fontsize=9, weight="bold", ha="left", va="bottom", zorder=21))
        figure.canvas.draw_idle()

    label = widgets.Text(value=f"Meja {len(tables) + 1}", description="Label")
    table_picker = widgets.Dropdown(description="Meja", options=[])
    status = widgets.HTML(
        value=(
            "Klik kiri langsung pada floorplan untuk menambah titik. Minimal 3 titik, lalu tekan Tambah meja. "
            "Polygon akan ditutup otomatis saat disimpan sebagai meja."
        )
    )
    add_button = widgets.Button(description="Tambah meja", button_style="success")
    rename_button = widgets.Button(description="Ubah label")
    delete_button = widgets.Button(description="Hapus meja")
    undo_point_button = widgets.Button(description="Hapus titik terakhir")
    undo_button = widgets.Button(description="Undo meja terakhir")
    clear_button = widgets.Button(description="Hapus semua", button_style="warning")
    save_button = widgets.Button(description="Simpan & rebuild", button_style="primary")

    def refresh_picker() -> None:
        table_picker.options = [(table.get("label") or table["featureId"], table["featureId"]) for table in tables]

    def add_table(_: Any) -> None:
        if len(pending) < 3:
            status.value = "Polygon minimal tiga titik."
            return
        polygon = orient(Polygon(pending), sign=1.0)
        existing = [Polygon(table["geometryM"]["points"]) for table in tables]
        if not polygon.is_valid or polygon.area < 0.1 or not box(0, 0, width_m, height_m).covers(polygon):
            status.value = "Polygon tidak valid, terlalu kecil, atau keluar bounds venue."
            return
        if any(polygon.intersection(other).area > 1e-6 for other in existing):
            status.value = "Polygon meja tidak boleh bertumpang tindih dengan meja lain."
            return
        sequence = 1
        used = {table["featureId"] for table in tables}
        while f"table-{sequence:02d}" in used: sequence += 1
        table_id = f"table-{sequence:02d}"
        geometry = _polygon_geometry(polygon)
        normalized = [[x / width_m, y / height_m] for x, y in geometry["points"]]
        tables.append({"featureId": table_id, "label": label.value.strip() or table_id, "type": "table", "verified": True, "geometryM": geometry, "geometryNormalized": {"type": "polygon", "points": normalized}})
        pending.clear(); label.value = f"Meja {len(tables) + 1}"; refresh_picker(); table_picker.value = table_id; redraw(); status.value = f"{table_id} ditambahkan; belum disimpan."

    def add_point(event: Any) -> None:
        if event.inaxes is not axis or event.button != 1 or event.xdata is None or event.ydata is None:
            return
        x, y = float(event.xdata), float(event.ydata)
        if not (0 <= x <= width_m and 0 <= y <= height_m):
            return
        pending.append([x, y])
        redraw()
        status.value = f"Titik {len(pending)} ditambahkan: ({x:.2f} m, {y:.2f} m). Tambahkan titik lagi atau tekan Tambah meja."

    def rename(_: Any) -> None:
        selected_id = table_picker.value
        for table in tables:
            if table["featureId"] == selected_id:
                table["label"] = label.value.strip() or selected_id
                refresh_picker(); table_picker.value = selected_id; redraw(); status.value = f"Label {selected_id} diubah; belum disimpan."
                return

    def delete(_: Any) -> None:
        selected_id = table_picker.value
        if selected_id is None:
            return
        tables[:] = [table for table in tables if table["featureId"] != selected_id]
        refresh_picker(); redraw(); status.value = f"{selected_id} dihapus; belum disimpan."

    def undo(_: Any) -> None:
        if tables: tables.pop(); refresh_picker(); redraw(); status.value = "Meja terakhir dihapus; belum disimpan."

    def undo_point(_: Any) -> None:
        if pending:
            pending.pop()
            redraw()
            status.value = f"Titik dibatalkan. Tersisa {len(pending)} titik untuk meja baru."

    def clear(_: Any) -> None:
        tables.clear(); refresh_picker(); redraw(); status.value = "Semua meja dihapus; belum disimpan."

    def save(_: Any) -> None:
        payload = {"schemaVersion": "1.0", "venueFingerprint": result.venue_fingerprint, "coordinateSystem": {"unit": "meter", "orientation": "x_right_y_down", "widthM": width_m, "heightM": height_m}, "tables": tables}
        validate_table_context(payload, width_m, height_m)
        result.context_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = result.context_path.with_suffix(".tmp")
        _write_json(temporary, payload); temporary.replace(result.context_path)
        status.value = f"Annotation disimpan: {result.context_path}"
        if rebuild:
            rebuilt = run_analysis(AnalysisConfig.default(job_id=result.job_id))
            status.value += f"<br>Package dibangun ulang: {rebuilt.output_dir}"

    connection_id = figure.canvas.mpl_connect("button_press_event", add_point)
    add_button.on_click(add_table); rename_button.on_click(rename); delete_button.on_click(delete); undo_point_button.on_click(undo_point); undo_button.on_click(undo); clear_button.on_click(clear); save_button.on_click(save)
    refresh_picker(); redraw()
    controls = widgets.VBox([
        widgets.HTML("<b>Canvas anotasi meja (embedded notebook)</b> — koordinat memakai meter: x ke kanan, y ke bawah."),
        widgets.HBox([label, add_button, undo_point_button]),
        widgets.HBox([table_picker, rename_button, delete_button, undo_button, clear_button, save_button]),
        status,
    ])
    # Keep the figure and click connection alive after this factory returns.
    controls._foodcourt_annotation_figure = figure
    controls._foodcourt_annotation_connection_id = connection_id
    display(figure)
    return controls
