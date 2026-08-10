"""
Tahap TRACKING: BoT-SORT (boxmot 13.0.17) mengonsumsi deteksi tersimpan.
Tetap membaca frame video karena ReID (OSNet) butuh crop appearance.
Lalu proyeksikan titik kaki tiap track ke bidang lantai via homografi.
"""
from collections import defaultdict
from pathlib import Path
import numpy as np
import cv2
from boxmot import BotSort

from .homography import project_points
from .detect import seek_accurate


def make_tracker(cfg):
    # API klasik boxmot 13.x. Param BoT-SORT tuned kamu (track_high_thresh,
    # match_thresh, appearance_thresh, proximity_thresh, track_buffer, dst)
    # bisa ditambahkan sebagai kwargs di sini.
    # ReID (OSNet) bisa dimatikan untuk kecepatan (fusion kita spasial).
    # ReID di CPU (default): model kecil lebih cepat di CPU daripada MPS.
    reid_dev = getattr(cfg, "REID_DEVICE", cfg.DEVICE)
    reid_half = cfg.HALF and reid_dev != "cpu"
    base = dict(reid_weights=Path(cfg.REID_WEIGHTS), device=reid_dev, half=reid_half)
    try:
        return BotSort(with_reid=getattr(cfg, "WITH_REID", True), **base)
    except TypeError:
        return BotSort(**base)


def track_from_dets(video_path: str, dets, cfg, on_frame=None):
    """
    dets: list[(frame_idx, t, boxes Nx5)] dari detect_video.
    Return:
      tracks: dict track_id -> list[(t, x1, y1, x2, y2, conf)]
      per_frame: dict frame_idx -> list[(track_id, x1, y1, x2, y2)]  (untuk render overlay)
    """
    tracker = make_tracker(cfg)
    dmap = {fi: boxes for (fi, t, boxes) in dets}
    tmap = {fi: t for (fi, t, boxes) in dets}
    frames_needed = set(dmap.keys())

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Tidak bisa membuka video: {video_path}")

    tracks = defaultdict(list)
    per_frame = {}
    track_feats = {}          # track_id -> embedding penampilan (EMA)
    n = len(dets)
    done = 0

    if not frames_needed:
        cap.release()
        return dict(tracks), per_frame, track_feats

    min_needed = min(frames_needed)
    max_needed = max(frames_needed)
    seek_accurate(cap, min_needed)   # frame-akurat
    idx = min_needed
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if idx > max_needed:
            break
        if idx in frames_needed:
            boxes = dmap[idx]
            if len(boxes):
                cls = np.zeros((len(boxes), 1), dtype=np.float32)      # person
                dets_in = np.hstack([boxes, cls]).astype(np.float32)   # Nx6 [x1,y1,x2,y2,conf,cls]
            else:
                dets_in = np.empty((0, 6), dtype=np.float32)

            # boxmot 13.x: update(dets, img) -> Nx8 [x1,y1,x2,y2,id,conf,cls,det_ind]
            try:
                out = tracker.update(dets_in, frame)
            except Exception:
                out = np.empty((0, 8), dtype=np.float32)   # frame bermasalah -> lewati

            # Simpan embedding penampilan (EMA) per track dari state boxmot -> untuk fusion antar-kamera.
            try:
                for st in (getattr(tracker, "active_tracks", None) or []):
                    fid = getattr(st, "id", None)
                    fv = getattr(st, "smooth_feat", None)
                    if fv is None:
                        fv = getattr(st, "curr_feat", None)
                    if fid is not None and fv is not None:
                        track_feats[int(fid)] = np.asarray(fv, dtype=np.float32).reshape(-1)
            except Exception:
                pass

            t = tmap[idx]
            for row in out:
                x1, y1, x2, y2 = float(row[0]), float(row[1]), float(row[2]), float(row[3])
                tid = int(row[4])
                conf = float(row[5]) if len(row) > 5 else 0.0
                tracks[tid].append((t, x1, y1, x2, y2, conf))
                per_frame.setdefault(idx, []).append((tid, x1, y1, x2, y2))
            done += 1
            if on_frame:
                on_frame(done, n)
        idx += 1

    cap.release()
    return dict(tracks), per_frame, track_feats


def tracks_to_floor(tracks, H):
    """
    Proyeksikan titik kaki (bottom-center bbox, y2) tiap track ke meter di lantai.
    Foot point (y2) lebih penting daripada kualitas box keseluruhan untuk fidelity proyeksi.
    Return dict track_id -> list[(t, x_m, y_m)]
    """
    floor = {}
    for tid, obs in tracks.items():
        if not obs:
            continue
        foot_px = np.array([[(o[1] + o[3]) / 2.0, o[4]] for o in obs], dtype=np.float32)
        proj = project_points(H, foot_px)
        floor[tid] = [(obs[i][0], float(proj[i][0]), float(proj[i][1])) for i in range(len(obs))]
    return floor