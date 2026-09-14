"""End-to-end job orchestration."""
import json
from pathlib import Path

import cv2

from config import Config
from model_registry import resolve_detection_model
from models import Artifacts, IdentityQuality, JobRequest, JobResult, OverlayVideo
from .analytics import compute_analytics
from .detect import detect_video, load_model
from .fuse import fuse_tracklets
from .homography import evaluate_calibration
from .render import render_bbox_video, render_combined_video, render_heatmap, render_path_video
from .track import build_tracklets, TrackingSession
from .performance import CameraCache, Timings, camera_cache_key
from .timing import camera_source_start


def _video_wh(path):
    cap = cv2.VideoCapture(path)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    if width <= 0 or height <= 0:
        raise RuntimeError(f"Tidak dapat membaca resolusi video: {path}")
    return width, height


def run_job(job_id: str, req: JobRequest, progress) -> JobResult:
    cfg, cameras, venue = Config, req.cameras, req.venue
    import torch
    torch.set_num_threads(getattr(cfg, "TORCH_THREADS", 1))
    detector_spec = resolve_detection_model(req.detectionModel)
    camera_count = len(cameras)
    if camera_count > 1 and not cfg.WITH_REID:
        raise RuntimeError("Job multi-kamera mewajibkan OSNet ReID; PRISM_WITH_REID tidak boleh 0")

    print(
        f"[engine] detector={cfg.DEVICE} reid={cfg.REID_DEVICE} "
        f"reid_on={cfg.WITH_REID} model={detector_spec.id} path={detector_spec.path} imgsz={cfg.IMGSZ} "
        f"proc_fps={cfg.PROC_FPS} batch={cfg.BATCH_SIZE}",
        flush=True,
    )
    workdir = Path(cfg.WORKDIR) / job_id
    workdir.mkdir(parents=True, exist_ok=True)
    timings = Timings(workdir / "performance.json")
    cache = CameraCache(cfg)
    camera_sizes = [_video_wh(camera.videoPath) for camera in cameras]

    calibrations, calibration_warnings = [], []
    for index, camera in enumerate(cameras):
        width, height = camera_sizes[index]
        try:
            evaluation = evaluate_calibration(
                camera, width, height, venue.widthM, venue.heightM, cfg
            )
        except ValueError as exc:
            raise RuntimeError(f"Kalibrasi kamera '{camera.label}' invalid: {exc}") from exc
        calibrations.append(evaluation)
        calibration_warnings.extend(
            f"{camera.label}: {warning}" for warning in evaluation.warnings
        )

    progress("detection", 0.0)
    model = None
    camera_detections = []
    all_tracklets, camera_render, tracking_warnings = [], [], []
    for index, camera in enumerate(cameras):
        source_start = camera_source_start(camera)
        if source_start < 0:
            raise RuntimeError(f"Offset kamera '{camera.label}' menghasilkan waktu sumber negatif")
        key = camera_cache_key(camera, detector_spec.path, cfg)
        with timings.measure("cacheRead"):
            cached = cache.load(key)
        if cached is not None:
            detection, tracking = cached
            timings.cache_hits += 1
        else:
            if model is None:
                with timings.measure("detectorLoad"):
                    model = load_model(cfg, detector_spec.path)
            with timings.measure("trackerLoad"):
                tracking_session = TrackingSession(cfg)
            def consume(batch, frames):
                with timings.measure("trackingReID"):
                    for (fi, time, boxes), frame in zip(batch, frames):
                        tracking_session.consume(fi, time, boxes, frame)
            def on_detection(done, total):
                progress("detection", 0.70 * (index + done / max(total, 1)) / camera_count)
            with timings.measure("decodeDetectionTracking"):
                detection = detect_video(model, camera.videoPath, cfg, on_detection,
                    start_sec=source_start, duration_sec=camera.durationSec, on_batch=consume)
            tracking = tracking_session.result()
            with timings.measure("cacheWrite"):
                cache.store(key, detection, tracking)
            del tracking_session
        camera_detections.append(detection)
        tracks, per_frame, samples, warnings = tracking
        progress("tracking", 0.70 * (index + 1) / camera_count)
        for warning in warnings:
            tracking_warnings.append({"camera": index, "label": camera.label, **warning})
        all_tracklets.extend(
            build_tracklets(
                index,
                tracks,
                samples,
                calibrations[index].pixel_to_world,
                calibrations[index].uncertainty_m,
            )
        )
        camera_render.append({"per_frame": per_frame})

    del model
    progress("fusion", 0.72)
    with timings.measure("fusion"):
        fusion = fuse_tracklets(all_tracklets, cfg)
    from .bounds import clamp_world
    if venue.floorBounds is not None:
        fusion.global_tracks = {gid: [(t, *clamp_world(x,y,venue)) for t,x,y in obs]
                                for gid,obs in fusion.global_tracks.items()}
    progress("fusion", 0.78)
    print(
        f"[engine] fusion global={len(fusion.global_tracks)} local={fusion.local_stitches} "
        f"overlap={fusion.overlap_merges} handover={fusion.handover_merges} "
        f"filtered={fusion.filtered_tracklets}",
        flush=True,
    )

    diagnostics_path = workdir / "fusion_diagnostics.json"
    calibration_diagnostics = [
        {
            "camera": index,
            "label": cameras[index].label,
            "legacyCalibration": value.legacy_calibration,
            "medianErrorM": value.median_error_m,
            "p95ErrorM": value.p95_error_m,
            "inlierMask": value.inlier_mask,
            "cameraCoverage": value.image_coverage,
            "floorCoverage": value.plane_coverage,
            "warnings": value.warnings,
            "clientMetricDifferences": value.client_metric_differences,
        }
        for index, value in enumerate(calibrations)
    ]
    diagnostics_path.write_text(
        json.dumps(
            {
                "associations": fusion.diagnostics,
                "trackingWarnings": tracking_warnings,
                "detectionModel": detector_spec.id,
                "calibrations": calibration_diagnostics,
            },
            indent=2,
            allow_nan=False,
        ),
        encoding="utf-8",
    )

    progress("analytics", 0.80)
    with timings.measure("analytics"):
        analytics, heat_grid = compute_analytics(fusion.global_tracks, venue, cfg)
    artifacts = Artifacts(fusionDiagnostics=diagnostics_path.as_uri())
    heat_path = workdir / "heatmap.png"
    render_heatmap(heat_grid, heat_path, bg_path=venue.floorPlanPath)
    artifacts.heatmapImage = heat_path.as_uri()

    if req.options.renderVideos:
        progress("rendering", 0.82)
        from .privacy import PersonPrivacy
        with timings.measure("privacyModelLoad"):
            privacy = PersonPrivacy(cfg.DEVICE)
        with timings.measure("privacyAndVideoEncoding"):
            if camera_count >= 2:
                combined = workdir / "combined.mp4"
                render_combined_video(
                    cameras,
                    camera_detections,
                    camera_render,
                    fusion.cam_to_global,
                    fusion.identity_confidence,
                    fusion.global_tracks,
                    venue,
                    cfg,
                    combined,
                    bg_path=venue.floorPlanPath,
                    privacy=privacy,
                    on_frame=lambda done,total: progress("rendering",.82+.10*done/max(total,1)),
                )
                if combined.exists():
                    artifacts.combinedVideo = combined.as_uri()
            else:
                overlays = []
                for index, camera in enumerate(cameras):
                    output = workdir / f"cam{index}_boxes.mp4"
                    render_bbox_video(
                        camera.videoPath,
                        camera_render[index],
                        fusion.cam_to_global,
                        fusion.identity_confidence,
                        index,
                        cfg,
                        output,
                        privacy=privacy,
                        on_frame=lambda done,total: progress("rendering",.82+.10*done/max(total,1)),
                    )
                    if output.exists():
                        overlays.append(OverlayVideo(cam=camera.label, uri=output.as_uri()))
                artifacts.overlayVideos = overlays

            path_video = workdir / "paths.mp4"
            render_path_video(
                fusion.global_tracks, venue, cfg, path_video, bg_path=venue.floorPlanPath,
                on_frame=lambda done,total: progress("rendering",.92+.04*done/max(total,1))
            )
            if path_video.exists():
                artifacts.pathVideo = path_video.as_uri()

        timings.seconds["privacyInference"] = privacy.inference_seconds
        del privacy

    progress("rendering", 0.96)
    trajectories = _write_trajectories(
        fusion.global_tracks,
        fusion.identity_confidence,
        workdir / "trajectories.parquet",
    )
    levels = [value["level"] for value in fusion.identity_confidence.values()]
    quality = IdentityQuality(
        globalIds=len(fusion.global_tracks),
        localStitches=fusion.local_stitches,
        overlapMerges=fusion.overlap_merges,
        handoverMerges=fusion.handover_merges,
        unmatchedTracklets=fusion.unmatched_tracklets,
        filteredTracklets=fusion.filtered_tracklets,
        highConfidence=levels.count("high"),
        mediumConfidence=levels.count("medium"),
        lowConfidence=levels.count("low"),
        singleCamera=levels.count("singleCamera"),
        calibrationWarnings=calibration_warnings,
    )
    from .heatmap_grid import build_heatmap_grid
    result = JobResult(
        heatmapGrid=build_heatmap_grid(fusion.global_tracks, venue, cfg),
        jobId=job_id,
        venue=venue,
        summary=analytics["summary"],
        zones=analytics["zones"],
        stopPoints=analytics["stopPoints"],
        occupancy=analytics["occupancy"],
        blobs=analytics["blobs"],
        paths=analytics["paths"],
        observations=analytics["observations"],
        artifacts=artifacts,
        trajectories=trajectories,
        identityQuality=quality,
    )
    timings.save()
    progress("done", 1.0)
    return result


def _write_trajectories(global_tracks, identity_confidence, path):
    try:
        import pandas as pd

        rows = [
            (
                time,
                global_id,
                x,
                y,
                identity_confidence.get(global_id, {}).get("score"),
                identity_confidence.get(global_id, {}).get("level", "singleCamera"),
            )
            for global_id, observations in global_tracks.items()
            for (time, x, y) in observations
        ]
        pd.DataFrame(
            rows, columns=["t", "id", "x", "y", "identityScore", "identityLevel"]
        ).to_parquet(path)
        return path.as_uri()
    except Exception as exc:
        print(f"[engine] trajectory parquet tidak tersedia: {exc}", flush=True)
        return None
