"""BoT-SORT tracking with one-pass OSNet descriptors attached through det_ind."""
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np

from .detect import seek_accurate
from .homography import project_points
from .tracklet import TrackAppearanceSampler, Tracklet


def make_tracker(cfg):
    try:
        from boxmot import BotSort
    except Exception as exc:
        raise RuntimeError(f"BoxMOT tidak dapat dimuat: {exc}") from exc

    reid_device = getattr(cfg, "REID_DEVICE", cfg.DEVICE)
    reid_half = cfg.HALF and reid_device != "cpu"
    base = dict(reid_weights=Path(cfg.REID_WEIGHTS), device=reid_device, half=reid_half)
    try:
        try:
            tracker = BotSort(with_reid=getattr(cfg, "WITH_REID", True), **base)
        except TypeError:
            tracker = BotSort(**base)
    except Exception as exc:
        raise RuntimeError(
            f"OSNet/BoT-SORT gagal dimuat dari '{cfg.REID_WEIGHTS}': {exc}"
        ) from exc
    if getattr(cfg, "WITH_REID", True) and getattr(tracker, "model", None) is None:
        raise RuntimeError("OSNet wajib aktif tetapi model ReID BoT-SORT tidak tersedia")
    return tracker


def _valid_crop_indices(dets_in: np.ndarray, frame: np.ndarray) -> tuple[list[int], list[str]]:
    height, width = frame.shape[:2]
    valid, warnings = [], []
    for index, row in enumerate(dets_in):
        x1, y1, x2, y2 = [float(value) for value in row[:4]]
        if not np.isfinite(row[:5]).all() or x2 <= x1 or y2 <= y1:
            warnings.append(f"detection[{index}] bbox rusak; crop dilewati")
            continue
        if x2 <= 0 or y2 <= 0 or x1 >= width or y1 >= height:
            warnings.append(f"detection[{index}] di luar frame; crop dilewati")
            continue
        valid.append(index)
    return valid, warnings


def extract_embeddings_once(tracker, dets_in: np.ndarray, frame: np.ndarray):
    """Return filtered detections, their embeddings, original indices, and crop warnings."""
    valid_indices, warnings = _valid_crop_indices(dets_in, frame)
    if not valid_indices:
        return np.empty((0, 6), dtype=np.float32), None, [], warnings

    filtered = dets_in[valid_indices]
    try:
        embeddings = np.asarray(
            tracker.model.get_features(filtered[:, :4], frame), dtype=np.float32
        )
    except Exception as exc:
        raise RuntimeError(f"OSNet gagal menghitung descriptor: {exc}") from exc
    if embeddings.ndim == 1:
        embeddings = embeddings.reshape(1, -1)
    if len(embeddings) != len(filtered):
        raise RuntimeError(
            f"OSNet mengembalikan {len(embeddings)} descriptor untuk {len(filtered)} deteksi"
        )

    feature_ok = np.isfinite(embeddings).all(axis=1) & (np.linalg.norm(embeddings, axis=1) > 1e-12)
    for local_index, is_valid in enumerate(feature_ok):
        if not is_valid:
            warnings.append(
                f"detection[{valid_indices[local_index]}] descriptor rusak; crop dilewati"
            )
    if bool(np.all(feature_ok)):
        return filtered, embeddings, valid_indices, warnings
    kept = np.flatnonzero(feature_ok)
    return (
        filtered[kept],
        embeddings[kept],
        [valid_indices[int(index)] for index in kept],
        warnings,
    )


def track_from_dets(video_path: str, dets, cfg, on_frame=None, tracker=None):
    """
    Return tracks, per-frame boxes, sampled descriptors, and non-fatal crop warnings.

    The exact embedding array passed to tracker.update is later recovered through
    BoxMOT's det_ind output; embeddings are never serialized.
    """
    tracker = tracker or make_tracker(cfg)
    dmap = {frame_index: boxes for (frame_index, _time, boxes) in dets}
    tmap = {frame_index: time for (frame_index, time, _boxes) in dets}
    frames_needed = set(dmap)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Tidak bisa membuka video: {video_path}")

    tracks = defaultdict(list)
    samplers = defaultdict(
        lambda: TrackAppearanceSampler(
            bin_seconds=cfg.REID_SAMPLE_BIN_SEC,
            max_samples=cfg.REID_MAX_SAMPLES,
            min_confidence=cfg.REID_SAMPLE_CONF,
        )
    )
    per_frame: dict[int, list[tuple[int, float, float, float, float, float]]] = {}
    warnings: list[dict] = []
    done = 0

    if not frames_needed:
        cap.release()
        return {}, per_frame, {}, warnings

    minimum, maximum = min(frames_needed), max(frames_needed)
    seek_accurate(cap, minimum)
    frame_index = minimum
    try:
        while True:
            ok, frame = cap.read()
            if not ok or frame_index > maximum:
                break
            if frame_index in frames_needed:
                boxes = dmap[frame_index]
                if len(boxes):
                    classes = np.zeros((len(boxes), 1), dtype=np.float32)
                    dets_in = np.hstack([boxes, classes]).astype(np.float32)
                else:
                    dets_in = np.empty((0, 6), dtype=np.float32)

                embeddings = None
                if len(dets_in) and getattr(cfg, "WITH_REID", True):
                    dets_in, embeddings, _original_indices, crop_warnings = extract_embeddings_once(
                        tracker, dets_in, frame
                    )
                    warnings.extend(
                        {"frame": frame_index, "reason": reason} for reason in crop_warnings
                    )

                try:
                    out = tracker.update(dets_in, frame, embs=embeddings)
                except Exception as exc:
                    raise RuntimeError(
                        f"BoT-SORT gagal pada frame {frame_index}: {type(exc).__name__}: {exc}"
                    ) from exc

                time = float(tmap[frame_index])
                for row in out:
                    x1, y1, x2, y2 = [float(value) for value in row[:4]]
                    track_id = int(row[4])
                    confidence = float(row[5]) if len(row) > 5 else 0.0
                    tracks[track_id].append((time, x1, y1, x2, y2, confidence))
                    per_frame.setdefault(frame_index, []).append(
                        (track_id, x1, y1, x2, y2, confidence)
                    )

                    if embeddings is not None and len(row) > 7:
                        detection_index = int(row[7])
                        if 0 <= detection_index < len(embeddings):
                            samplers[track_id].add(
                                time, confidence, embeddings[detection_index]
                            )
                        else:
                            warnings.append(
                                {
                                    "frame": frame_index,
                                    "trackId": track_id,
                                    "reason": f"det_ind {detection_index} di luar descriptor batch",
                                }
                            )
                done += 1
                if on_frame:
                    on_frame(done, len(dets))
            frame_index += 1
    finally:
        cap.release()

    samples = {track_id: sampler.samples() for track_id, sampler in samplers.items()}
    return dict(tracks), per_frame, samples, warnings


def build_tracklets(camera_idx, tracks, samples, H, calibration_uncertainty_m):
    """Project bbox foot points and retain camera/local provenance."""
    result = []
    for track_id, observations in tracks.items():
        if not observations:
            continue
        foot_pixels = np.asarray(
            [[(obs[1] + obs[3]) / 2.0, obs[4]] for obs in observations], dtype=np.float32
        )
        projected = project_points(H, foot_pixels)
        floor = [
            (observations[index][0], float(point[0]), float(point[1]), observations[index][5])
            for index, point in enumerate(projected)
        ]
        result.append(
            Tracklet(
                camera_idx=int(camera_idx),
                local_track_id=int(track_id),
                source_local_ids={int(track_id)},
                bbox_observations=list(observations),
                floor_observations=floor,
                appearance_samples=list(samples.get(track_id, [])),
                calibration_uncertainty_m=float(calibration_uncertainty_m),
            )
        )
    return result


def tracks_to_floor(tracks, H):
    """Compatibility helper for callers that only need projected observations."""
    result = {}
    for track_id, observations in tracks.items():
        foot_pixels = np.asarray(
            [[(obs[1] + obs[3]) / 2.0, obs[4]] for obs in observations], dtype=np.float32
        )
        projected = project_points(H, foot_pixels)
        result[track_id] = [
            (observations[index][0], float(point[0]), float(point[1]))
            for index, point in enumerate(projected)
        ]
    return result
