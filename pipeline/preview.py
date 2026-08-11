"""Fast two-camera calibration preview with in-memory YOLO/OSNet caching."""
from __future__ import annotations

import base64
import secrets
import time
from dataclasses import dataclass

import cv2
import numpy as np
from scipy.optimize import linear_sum_assignment

from config import Config
from models import (
    CalibrationPreviewResponse,
    PreviewCameraOut,
    PreviewMarker,
    PreviewMatchOut,
)
from .detect import _boxes_from_result, seek_accurate
from .homography import evaluate_calibration, project_points
from .track import extract_embeddings_once, make_tracker
from .tracklet import AppearanceSample, TrackAppearanceSampler, Tracklet, appearance_similarity
from .timing import camera_source_time


@dataclass
class _PreviewDetection:
    local_id: int
    bbox: tuple[float, float, float, float]
    confidence: float
    foot_pixel: tuple[float, float]
    appearance_samples: list[AppearanceSample]


@dataclass
class _CachedCamera:
    camera_id: str
    label: str
    video_path: str
    source_time: float
    frame: np.ndarray
    width: int
    height: int
    detections: list[_PreviewDetection]


@dataclass
class _CachedPreview:
    created_at: float
    global_time: float
    cameras: list[_CachedCamera]
    inference_warnings: list[str]


class CalibrationPreviewManager:
    def __init__(self, cfg=Config):
        self.cfg = cfg
        self._detector = None
        self._reid_tracker = None
        self._cache: dict[str, _CachedPreview] = {}

    def _load_models(self, needs_reid: bool):
        if self._detector is None:
            try:
                from ultralytics import YOLO

                self._detector = YOLO(self.cfg.PREVIEW_YOLO_MODEL)
            except Exception as exc:
                raise RuntimeError(f"YOLO preview gagal dimuat: {exc}") from exc
        if needs_reid and self._reid_tracker is None:
            self._reid_tracker = make_tracker(self.cfg)

    def sample(self, request) -> CalibrationPreviewResponse:
        needs_reid = len(request.cameras) > 1
        self._load_models(needs_reid=needs_reid)
        loaded = []
        for camera in request.cameras:
            source_time = camera_source_time(camera, request.globalTimeSec)
            loaded.append(self._load_camera_frames(camera, source_time, burst=needs_reid))

        all_frames = [frame for item in loaded for frame in item["frames"]]
        try:
            results = self._detector.predict(
                all_frames,
                imgsz=self.cfg.PREVIEW_IMGSZ,
                conf=self.cfg.CONF,
                iou=self.cfg.IOU,
                classes=[self.cfg.PERSON_CLASS],
                device=self.cfg.DEVICE,
                verbose=False,
            )
        except Exception as exc:
            raise RuntimeError(f"YOLO preview gagal melakukan inference: {exc}") from exc

        cached_cameras, inference_warnings = [], []
        cursor = 0
        for camera_index, (camera, item) in enumerate(zip(request.cameras, loaded)):
            camera_results = results[cursor:cursor + len(item["frames"])]
            cursor += len(item["frames"])
            if needs_reid:
                detections, warnings = self._build_camera_detections(
                    camera_index,
                    item["frames"],
                    item["times"],
                    item["center_index"],
                    camera_results,
                )
            else:
                detections = self._build_single_camera_detections(camera_results[0])
                warnings = []
            inference_warnings.extend(f"{camera.label}: {warning}" for warning in warnings)
            center = item["frames"][item["center_index"]]
            cached_cameras.append(
                _CachedCamera(
                    camera_id=self._camera_id(camera, camera_index),
                    label=camera.label,
                    video_path=camera.videoPath,
                    source_time=item["times"][item["center_index"]],
                    frame=center,
                    width=center.shape[1],
                    height=center.shape[0],
                    detections=detections,
                )
            )

        self._evict()
        token = secrets.token_urlsafe(16)
        self._cache[token] = _CachedPreview(
            created_at=time.monotonic(),
            global_time=float(request.globalTimeSec),
            cameras=cached_cameras,
            inference_warnings=inference_warnings,
        )
        return self._reproject(token, request.venue, request.cameras)

    def reproject(self, request) -> CalibrationPreviewResponse:
        return self._reproject(request.token, request.venue, request.cameras)

    def _load_camera_frames(self, camera, source_time: float, burst: bool = True):
        cap = cv2.VideoCapture(camera.videoPath)
        if not cap.isOpened():
            raise RuntimeError(f"Tidak bisa membuka video preview: {camera.videoPath}")
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 30.0)
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        duration = total / fps if total > 0 else 0.0
        if source_time < 0 or (duration > 0 and source_time > duration):
            cap.release()
            raise ValueError(
                f"timestamp {source_time:.2f}s di luar durasi kamera '{camera.label}'"
            )
        if not burst:
            upper = max(0.0, duration - 1.0 / fps) if duration > 0 else source_time
            requested = [source_time]
            center_index = 0
        else:
            delta = max(float(self.cfg.PREVIEW_SAMPLE_DELTA_SEC), 0.05)
            upper = max(0.0, duration - 1.0 / fps) if duration > 0 else source_time + delta
            if source_time - delta < 0:
                requested = [source_time, source_time + delta, source_time + 2 * delta]
                center_index = 0
            elif source_time + delta > upper:
                requested = [source_time - 2 * delta, source_time - delta, source_time]
                center_index = 2
            else:
                requested = [source_time - delta, source_time, source_time + delta]
                center_index = 1
        times = [min(upper, max(0.0, value)) for value in requested]
        frames = []
        for sample_time in times:
            target = max(0, int(round(sample_time * fps)))
            seek_accurate(cap, target)
            ok, frame = cap.read()
            if not ok or frame is None:
                cap.release()
                raise RuntimeError(f"Frame preview '{camera.label}' pada {sample_time:.2f}s tidak tersedia")
            frames.append(frame)
        cap.release()
        return {"frames": frames, "times": times, "center_index": center_index}

    def _build_single_camera_detections(self, result):
        """One-frame YOLO-only path for calibration projection validation."""
        output = []
        for index, row in enumerate(_boxes_from_result(result)):
            x1, y1, x2, y2, confidence = [float(value) for value in row]
            output.append(
                _PreviewDetection(
                    local_id=index + 1,
                    bbox=(x1, y1, x2, y2),
                    confidence=confidence,
                    foot_pixel=((x1 + x2) / 2.0, y2),
                    appearance_samples=[],
                )
            )
        return output

    def _features_for_frame(self, boxes, frame, camera_index, sample_index):
        if not len(boxes):
            return np.empty((0, 5), dtype=np.float32), np.empty((0, 0), dtype=np.float32), []
        classes = np.zeros((len(boxes), 1), dtype=np.float32)
        detections = np.hstack([boxes, classes]).astype(np.float32)
        filtered, embeddings, _indices, warnings = extract_embeddings_once(
            self._reid_tracker, detections, frame
        )
        if embeddings is None:
            embeddings = np.empty((0, 0), dtype=np.float32)
        return filtered[:, :5], embeddings, [
            f"camera {camera_index + 1} sample {sample_index + 1}: {warning}"
            for warning in warnings
        ]

    def _build_camera_detections(self, camera_index, frames, times, center_sample_index, results):
        samples, warnings = [], []
        for sample_index, (frame, result) in enumerate(zip(frames, results)):
            boxes = _boxes_from_result(result)
            filtered, embeddings, item_warnings = self._features_for_frame(
                boxes, frame, camera_index, sample_index
            )
            samples.append((filtered, embeddings))
            warnings.extend(item_warnings)

        center_boxes, center_embeddings = samples[center_sample_index]
        side_matches = {}
        for side_index in [index for index in range(len(samples)) if index != center_sample_index]:
            _side_boxes, side_embeddings = samples[side_index]
            mapping = {}
            if len(center_embeddings) and len(side_embeddings):
                similarities = center_embeddings @ side_embeddings.T
                rows, columns = linear_sum_assignment(-similarities)
                for row, column in zip(rows, columns):
                    if float(similarities[row, column]) >= 0.45:
                        mapping[int(row)] = int(column)
            side_matches[side_index] = mapping
        output = []
        for center_index, row in enumerate(center_boxes):
            sampler = TrackAppearanceSampler(
                bin_seconds=max(self.cfg.PREVIEW_SAMPLE_DELTA_SEC / 2.0, 0.05),
                max_samples=3,
                min_confidence=self.cfg.REID_SAMPLE_CONF,
            )
            if center_index < len(center_embeddings):
                sampler.add(
                    times[center_sample_index], float(row[4]), center_embeddings[center_index]
                )
            for side_index in side_matches:
                side_boxes, side_embeddings = samples[side_index]
                best = side_matches[side_index].get(center_index)
                if best is None:
                    continue
                sampler.add(times[side_index], float(side_boxes[best][4]), side_embeddings[best])
            x1, y1, x2, y2, confidence = [float(value) for value in row]
            output.append(
                _PreviewDetection(
                    local_id=center_index + 1,
                    bbox=(x1, y1, x2, y2),
                    confidence=confidence,
                    foot_pixel=((x1 + x2) / 2.0, y2),
                    appearance_samples=sampler.samples(),
                )
            )
        return output, warnings

    def _reproject(self, token, venue, cameras) -> CalibrationPreviewResponse:
        cached = self._cache.get(token)
        if cached is None or time.monotonic() - cached.created_at > self.cfg.PREVIEW_CACHE_TTL_SEC:
            self._cache.pop(token, None)
            raise KeyError("cache preview kedaluwarsa; ambil sampel ulang")
        if len(cameras) != len(cached.cameras):
            raise ValueError("jumlah kamera preview berubah")

        evaluations, tracklets, calibration_warnings = [], [], []
        for index, (camera, stored) in enumerate(zip(cameras, cached.cameras)):
            if (
                self._camera_id(camera, index) != stored.camera_id
                or camera.videoPath != stored.video_path
            ):
                raise ValueError("pasangan kamera preview berubah; ambil sampel ulang")
            expected_source_time = camera_source_time(camera, cached.global_time)
            if abs(expected_source_time - stored.source_time) >= 0.001:
                raise ValueError("waktu frame preview berubah; ambil sampel ulang")
            evaluation = evaluate_calibration(
                camera,
                stored.width,
                stored.height,
                venue.widthM,
                venue.heightM,
                self.cfg,
            )
            evaluations.append(evaluation)
            calibration_warnings.extend(
                f"{camera.label}: {warning}" for warning in evaluation.warnings
            )
            for detection in stored.detections:
                world = project_points(evaluation.pixel_to_world, [detection.foot_pixel])[0]
                tracklets.append(
                    Tracklet(
                        camera_idx=index,
                        local_track_id=detection.local_id,
                        source_local_ids={detection.local_id},
                        bbox_observations=[(
                            cached.global_time,
                            *detection.bbox,
                            detection.confidence,
                        )],
                        floor_observations=[(
                            cached.global_time,
                            float(world[0]),
                            float(world[1]),
                            detection.confidence,
                        )],
                        appearance_samples=detection.appearance_samples,
                        calibration_uncertainty_m=evaluation.uncertainty_m,
                    )
                )

        left = [item for item in tracklets if item.camera_idx == 0]
        right = [item for item in tracklets if item.camera_idx == 1]
        matches, accepted = self._associate(left, right)
        identity = {}
        for global_id, (left_index, right_index, score) in enumerate(accepted, start=1):
            level = "high" if score >= 0.80 else ("medium" if score >= 0.70 else "low")
            identity[(0, left[left_index].local_track_id)] = (global_id, score, level)
            identity[(1, right[right_index].local_track_id)] = (global_id, score, level)

        camera_outputs = []
        for camera_index, (camera, stored) in enumerate(zip(cameras, cached.cameras)):
            markers = []
            for detection in stored.detections:
                tracklet = next(
                    item for item in tracklets
                    if item.camera_idx == camera_index and item.local_track_id == detection.local_id
                )
                _time, world_x, world_y, _confidence = tracklet.floor_observations[0]
                assigned = identity.get((camera_index, detection.local_id))
                if assigned:
                    global_id, score, level = assigned
                    label = f"ID {global_id}"
                else:
                    global_id, score, level = None, None, "singleCamera"
                    label = (
                        f"Person {detection.local_id}"
                        if len(cameras) == 1
                        else f"C{camera_index + 1}-L{detection.local_id}"
                    )
                x1, y1, x2, y2 = detection.bbox
                markers.append(
                    PreviewMarker(
                        cameraIndex=camera_index,
                        localId=detection.local_id,
                        identityLabel=label,
                        globalId=global_id,
                        bboxNorm=[x1 / stored.width, y1 / stored.height, x2 / stored.width, y2 / stored.height],
                        confidence=detection.confidence,
                        worldX=world_x,
                        worldY=world_y,
                        identityScore=score,
                        identityLevel=level,
                    )
                )
            annotated = self._annotated_jpeg(stored.frame, markers)
            camera_outputs.append(
                PreviewCameraOut(
                    cameraIndex=camera_index,
                    cameraId=stored.camera_id,
                    label=camera.label,
                    videoPath=stored.video_path,
                    calibrationFingerprint=camera.calibrationFingerprint or "",
                    sourceTimeSec=stored.source_time,
                    frameWidth=stored.width,
                    frameHeight=stored.height,
                    frameJpegBase64=annotated,
                    markers=markers,
                )
            )
        return CalibrationPreviewResponse(
            token=token,
            globalTimeSec=cached.global_time,
            cameras=camera_outputs,
            matches=matches,
            calibrationWarnings=calibration_warnings,
            inferenceWarnings=cached.inference_warnings,
        )

    @staticmethod
    def _camera_id(camera, camera_index: int) -> str:
        return camera.cameraId or f"legacy:{camera_index}:{camera.videoPath}"

    def _associate(self, left: list[Tracklet], right: list[Tracklet]):
        records, eligible = [], []
        for row, first in enumerate(left):
            for column, second in enumerate(right):
                similarity = appearance_similarity(first, second, self.cfg.REID_MIN_SAMPLES)
                distance = float(np.linalg.norm(
                    np.subtract(first.start_position, second.start_position)
                ))
                strict_gate = max(
                    self.cfg.OVERLAP_BASE_RADIUS_M,
                    float(np.hypot(
                        first.calibration_uncertainty_m,
                        second.calibration_uncertainty_m,
                    )) + 0.25,
                )
                appearance_match = (
                    similarity is not None
                    and similarity >= self.cfg.OVERLAP_MIN_SIM
                )
                gate = max(
                    strict_gate,
                    getattr(self.cfg, "OVERLAP_APPEARANCE_RADIUS_M", strict_gate)
                    if appearance_match
                    else strict_gate,
                )
                reason = "eligible"
                if similarity is None:
                    reason = "insufficientEmbeddingSamples"
                elif similarity < self.cfg.OVERLAP_MIN_SIM:
                    reason = "appearanceBelowThreshold"
                elif distance > gate:
                    reason = "distanceOutsideUncertaintyGate"
                spatial = max(0.0, 1.0 - distance / max(gate, 1e-6))
                score = None if similarity is None else 0.65 * similarity + 0.35 * spatial
                record = PreviewMatchOut(
                    cameraALocalId=first.local_track_id,
                    cameraBLocalId=second.local_track_id,
                    similarity=similarity,
                    distanceM=distance,
                    uncertaintyGateM=gate,
                    score=score,
                    decision="rejected",
                    reason=reason,
                )
                records.append(record)
                if reason == "eligible":
                    eligible.append((row, column, score, len(records) - 1))

        accepted = []
        if eligible:
            matrix = np.full((len(left), len(right)), 1e6, dtype=np.float64)
            lookup = {}
            for row, column, score, record_index in eligible:
                matrix[row, column] = 1.0 - score
                lookup[(row, column)] = record_index
            rows, columns = linear_sum_assignment(matrix)
            for row, column in zip(rows, columns):
                record_index = lookup.get((int(row), int(column)))
                if record_index is None or matrix[row, column] >= 1e5:
                    continue
                record = records[record_index]
                record.decision = "accepted"
                record.reason = "hungarianMatch"
                accepted.append((int(row), int(column), float(record.score)))
            selected = {lookup[(row, column)] for row, column, _score in accepted if (row, column) in lookup}
            for _row, _column, _score, record_index in eligible:
                if record_index not in selected:
                    records[record_index].reason = "notSelectedByHungarian"
        return records, accepted

    def _annotated_jpeg(self, frame, markers):
        output = frame.copy()
        height, width = output.shape[:2]
        for marker in markers:
            x1, y1, x2, y2 = marker.bboxNorm
            p1 = (int(x1 * width), int(y1 * height))
            p2 = (int(x2 * width), int(y2 * height))
            color = (90, 190, 90) if marker.globalId is not None else (150, 150, 150)
            cv2.rectangle(output, p1, p2, color, max(2, width // 900))
            suffix = "" if marker.identityScore is None else f" {marker.identityScore:.2f}"
            cv2.putText(
                output,
                marker.identityLabel + suffix,
                (p1[0], max(18, p1[1] - 7)),
                cv2.FONT_HERSHEY_SIMPLEX,
                max(0.5, width / 2300.0),
                color,
                max(1, width // 1200),
            )
        scale = min(1.0, 1100.0 / max(width, 1))
        if scale < 1.0:
            output = cv2.resize(output, (int(width * scale), int(height * scale)))
        ok, encoded = cv2.imencode(".jpg", output, [cv2.IMWRITE_JPEG_QUALITY, 84])
        if not ok:
            raise RuntimeError("gagal mengenkode frame preview")
        return base64.b64encode(encoded.tobytes()).decode("ascii")

    def _evict(self):
        now = time.monotonic()
        expired = [
            token for token, value in self._cache.items()
            if now - value.created_at > self.cfg.PREVIEW_CACHE_TTL_SEC
        ]
        for token in expired:
            self._cache.pop(token, None)
        overflow = len(self._cache) - max(self.cfg.PREVIEW_CACHE_MAX - 1, 0)
        if overflow > 0:
            oldest = sorted(self._cache, key=lambda token: self._cache[token].created_at)
            for token in oldest[:overflow]:
                self._cache.pop(token, None)
