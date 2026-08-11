"""
Orkestrator: satu job end-to-end.
Progress dipetakan ke 4 tahap yang sama dengan UI:
  detection 0.00–0.45 | tracking 0.45–0.70 | fusion 0.70–0.78 | analytics+render 0.78–1.00
"""
from pathlib import Path
import cv2

from config import Config
from models import JobRequest, JobResult, Artifacts, OverlayVideo
from .homography import homography_pixel_to_meter
from .detect import load_model, detect_video
from .track import track_from_dets, tracks_to_floor
from .fuse import fuse_tracks, stitch_tracks
from .analytics import compute_analytics
from .render import render_heatmap, render_bbox_video, render_path_video, render_combined_video


def _video_wh(path):
    cap = cv2.VideoCapture(path)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    return w, h


def run_job(job_id: str, req: JobRequest, progress) -> JobResult:
    cfg = Config
    cams = req.cameras
    venue = req.venue
    n = len(cams)

    print(f"[engine] detector={cfg.DEVICE} reid={getattr(cfg, 'REID_DEVICE', cfg.DEVICE)} "
          f"reid_on={getattr(cfg, 'WITH_REID', True)} model={cfg.YOLO_MODEL} "
          f"imgsz={cfg.IMGSZ} proc_fps={cfg.PROC_FPS} batch={getattr(cfg, 'BATCH_SIZE', 1)}", flush=True)
    for c in cams:
        print(f"[engine] cam '{c.label}': start={c.startSec}s dur={c.durationSec}s", flush=True)

    workdir = Path(cfg.WORKDIR) / job_id
    workdir.mkdir(parents=True, exist_ok=True)

    cam_wh = [_video_wh(c.videoPath) for c in cams]

    # ---------- Stage 1: DETECTION ----------
    progress("detection", 0.0)
    model = load_model(cfg)
    cam_det = []
    for i, c in enumerate(cams):
        def on_frame(done, total, i=i):
            progress("detection", 0.45 * (i + done / max(total, 1)) / n)
        cam_det.append(detect_video(model, c.videoPath, cfg, on_frame,
                                    start_sec=c.startSec, duration_sec=c.durationSec))

    # ---------- Stage 2: TRACKING (+ proyeksi lantai) ----------
    cam_floor, cam_render, cam_feats = [], [], []
    for i, c in enumerate(cams):
        def on_frame(done, total, i=i):
            progress("tracking", 0.45 + 0.25 * (i + done / max(total, 1)) / n)
        tracks, per_frame, feats = track_from_dets(c.videoPath, cam_det[i]["dets"], cfg, on_frame)
        w, h = cam_wh[i]
        H = homography_pixel_to_meter(c.imagePoints, c.planePoints, w, h, venue.widthM, venue.heightM)
        cam_floor.append(tracks_to_floor(tracks, H))
        cam_render.append({"per_frame": per_frame})
        cam_feats.append(feats)

    # ---------- Stage 3: FUSION ----------
    progress("fusion", 0.72)
    global_tracks, cam_to_global = fuse_tracks(cam_floor, cfg, cam_feats=cam_feats)

    # ID stitching: sambung fragmen jadi orang utuh (kurangi over-counting).
    before_stitch = len(global_tracks)
    global_tracks, remap = stitch_tracks(global_tracks, cfg)
    cam_to_global = {k: remap.get(v, v) for k, v in cam_to_global.items()}
    print(f"[engine] stitch: {before_stitch} -> {len(global_tracks)} track", flush=True)

    # Buang fragmen/false-positive: track terlalu pendek jarang orang nyata.
    _min_sec = getattr(cfg, "MIN_TRACK_SEC", 0.0)
    _min_pts = getattr(cfg, "MIN_TRACK_POINTS", 1)

    def _keep(obs):
        if len(obs) < _min_pts:
            return False
        ts = [o[0] for o in obs]
        return (max(ts) - min(ts)) >= _min_sec

    before = len(global_tracks)
    global_tracks = {g: o for g, o in global_tracks.items() if _keep(o)}
    print(f"[engine] track filter: {before} -> {len(global_tracks)} "
          f"(min {_min_sec}s / {_min_pts} titik)", flush=True)
    progress("fusion", 0.78)

    # ---------- Stage 4: ANALYTICS ----------
    progress("analytics", 0.80)
    res, heat_grid = compute_analytics(global_tracks, venue, cfg)

    artifacts = Artifacts()
    heat_path = workdir / "heatmap.png"
    render_heatmap(heat_grid, heat_path, bg_path=venue.floorPlanPath)
    artifacts.heatmapImage = heat_path.as_uri()

    if req.options.renderVideos:
        if len(cams) >= 2:
            # Multi-kamera: satu video gabungan (grid semua kamera + BEV fusion).
            combined = workdir / "combined.mp4"
            render_combined_video(cams, cam_det, cam_render, cam_to_global,
                                  global_tracks, venue, cfg, combined, bg_path=venue.floorPlanPath)
            if combined.exists():
                artifacts.combinedVideo = combined.as_uri()
        else:
            # Satu kamera: overlay bounding box biasa.
            overlays = []
            for i, c in enumerate(cams):
                outp = workdir / f"cam{i}_boxes.mp4"
                render_bbox_video(c.videoPath, cam_render[i], cam_to_global, i, cfg, outp)
                if outp.exists():
                    overlays.append(OverlayVideo(cam=c.label, uri=outp.as_uri()))
            artifacts.overlayVideos = overlays

        pv = workdir / "paths.mp4"
        render_path_video(global_tracks, venue, cfg, pv, bg_path=venue.floorPlanPath)
        if pv.exists():
            artifacts.pathVideo = pv.as_uri()

    progress("analytics", 0.96)

    traj_uri = _write_trajectories(global_tracks, workdir / "trajectories.parquet")

    result = JobResult(
        jobId=job_id,
        venue=venue,
        summary=res["summary"],
        zones=res["zones"],
        stopPoints=res["stopPoints"],
        occupancy=res["occupancy"],
        blobs=res["blobs"],
        paths=res["paths"],
        observations=res["observations"],
        artifacts=artifacts,
        trajectories=traj_uri,
    )
    progress("done", 1.0)
    return result


def _write_trajectories(global_tracks, path):
    """Ekspor (t, id, x, y) ke parquet — kontrak trajektori untuk Track B."""
    try:
        import pandas as pd
        rows = [(t, gid, x, y) for gid, obs in global_tracks.items() for (t, x, y) in obs]
        df = pd.DataFrame(rows, columns=["t", "id", "x", "y"])
        df.to_parquet(path)
        return path.as_uri()
    except Exception:
        return None