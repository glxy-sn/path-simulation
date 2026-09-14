"""
Tahap RENDER: hasilkan artifact yang ditampilkan di layar Hasil.
- heatmap.png       : bird's-eye heatmap
- camN_boxes.mp4    : video deteksi + bounding box + ID global + titik kaki
- paths.mp4         : simulasi jalur di bidang lantai
Video adalah bagian termahal; bisa dimatikan lewat options.renderVideos.
"""
import os
import math
import numpy as np
import cv2

from .detect import seek_accurate
from .timing import camera_source_start

from .video_writer import VideoWriter
from .path_selection import select_detail_paths, synchronize_detail_paths, detail_path_groups

BOX_LABEL_FONT_SCALE = 0.38
PATH_VIDEO_DURATION_SEC = 10
PATH_VIDEO_FPS = 30


def _open_writer(path, fps, size):
    return VideoWriter(path, fps, size)


def _load_bg(path, w, h):
    """Muat floor map sebagai background (di-resize ke kanvas). None kalau tak ada/gagal."""
    if not path:
        return None
    img = cv2.imread(str(path))
    if img is None:
        return None
    return cv2.resize(img, (w, h))


def render_heatmap(heat: np.ndarray, out_path, out_w: int = 720, bg_path=None):
    gh, gw = heat.shape
    norm = heat / heat.max() if heat.max() > 0 else heat
    small = (norm * 255).astype(np.uint8)
    out_h = max(1, int(out_w * gh / max(gw, 1)))
    big = cv2.resize(small, (out_w, out_h), interpolation=cv2.INTER_LINEAR)
    big = cv2.GaussianBlur(big, (0, 0), sigmaX=out_w / 90.0)
    color = cv2.applyColorMap(big, cv2.COLORMAP_TURBO)

    bg = _load_bg(bg_path, out_w, out_h)
    if bg is not None:
        alpha = (np.clip(big.astype(np.float32) / 255.0, 0, 1) * 0.7)[..., None]
        out = (color.astype(np.float32) * alpha + bg.astype(np.float32) * (1 - alpha)).astype(np.uint8)
    else:
        color[big < 8] = (36, 21, 15)   # area sepi -> gelap
        out = color
    cv2.imwrite(str(out_path), out)


def _identity_label(cam_idx, track_id, cam_to_global, identity_confidence):
    global_id = cam_to_global.get((cam_idx, track_id))
    if global_id is None:
        return None, f"C{cam_idx + 1}-L{int(track_id)}", (145, 145, 145)
    return global_id, f"ID {global_id}", _gid_color(global_id)


def render_bbox_video(video_path, cam_info, cam_to_global, identity_confidence, cam_idx, cfg, out_path, privacy=None, on_frame=None):
    from .privacy import PersonPrivacy
    privacy = privacy or PersonPrivacy(cfg.DEVICE)
    per_frame = cam_info["per_frame"]
    if not per_frame:
        return
    cap = cv2.VideoCapture(video_path)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    vw = _open_writer(out_path, cfg.PROC_FPS, (w, h))
    fset = set(per_frame.keys())
    min_fi = min(fset)
    max_fi = max(fset)
    seek_accurate(cap, min_fi)   # frame-akurat -> overlay sesuai window slider
    idx = min_fi
    pending, indices = [], []
    rendered = 0
    def flush():
        nonlocal rendered
        if not pending:
            return
        for fi, frame in zip(indices, privacy.redact_batch(pending)):
            _draw_global_boxes(frame, per_frame.get(fi, []), cam_idx, cam_to_global, identity_confidence)
            for box in per_frame.get(fi, []):
                _, x1, _, x2, y2 = box[:5]
                cv2.circle(frame, (int((x1+x2)/2),int(y2)), 4, (0,165,255), -1)
            vw.write(frame)
            rendered += 1
            if on_frame:
                on_frame(rendered, len(fset))
        pending.clear()
        indices.clear()
    try:
        while idx <= max_fi:
            if idx not in fset:
                if not cap.grab():
                    raise RuntimeError("Video ended during rendering")
            else:
                ret, frame = cap.read()
                if not ret:
                    raise RuntimeError("Video frame unavailable during rendering")
                pending.append(frame)
                indices.append(idx)
                if len(pending) >= max(1,int(os.getenv("PRISM_PRIVACY_BATCH","2"))):
                    flush()
            idx += 1
        flush()
    finally:
        cap.release()
        vw.release()


class TrailRenderer:
    """Project once and append each segment once, instead of redrawing history."""
    def __init__(self, global_tracks, venue, w, h, background, thickness=1):
        self.canvas = background.copy()
        self.thickness = thickness
        self.tracks = {}
        self.positions = {}
        W, H = float(venue.widthM), float(venue.heightM)
        for gid, obs in global_tracks.items():
            ordered = sorted(obs)
            self.tracks[gid] = [(t, (int(np.clip(x/W,0,1)*(w-1)),
                                      int(np.clip(y/H,0,1)*(h-1)))) for t,x,y in ordered]
            self.positions[gid] = 0
        self.colors = {gid: _gid_color(gid) for gid in self.tracks}

    def advance(self, time, labels=False):
        for gid, points in self.tracks.items():
            pos = self.positions[gid]
            while pos < len(points) and points[pos][0] <= time:
                if pos:
                    cv2.line(self.canvas, points[pos-1][1], points[pos][1], self.colors[gid], getattr(self, "widths", {}).get(gid, self.thickness))
                pos += 1
            self.positions[gid] = pos
        frame = self.canvas.copy()
        for gid, points in self.tracks.items():
            pos = self.positions[gid]
            if pos:
                point = points[pos-1][1]
                cv2.circle(frame, point, 3 if labels else 5, self.colors[gid], -1)
                if labels:
                    cv2.putText(frame,str(gid),(point[0]+3,point[1]),cv2.FONT_HERSHEY_SIMPLEX,0.35,self.colors[gid],1)
        return frame


def render_path_video(global_tracks, venue, cfg, out_path, canvas_w=900, bg_path=None, on_frame=None):
    canvas_h = max(1, int(canvas_w * float(venue.heightM) / max(float(venue.widthM), 1e-6)))
    times = [o[0] for obs in global_tracks.values() for o in obs]
    if not times:
        return
    bg = _load_bg(bg_path, canvas_w, canvas_h)
    if bg is None:
        bg = np.full((canvas_h,canvas_w,3),245,np.uint8)
    groups = detail_path_groups(global_tracks, venue)
    selected = synchronize_detail_paths({i+1: g["observations"] for i,g in enumerate(groups)},
                                        PATH_VIDEO_DURATION_SEC, PATH_VIDEO_DURATION_SEC * PATH_VIDEO_FPS)
    trail = TrailRenderer(selected, venue, canvas_w, canvas_h, bg, thickness=2)
    trail.widths = {i+1: 2+round(4*g["count"]/max([v["count"] for v in groups], default=1)) for i,g in enumerate(groups)}
    writer = _open_writer(out_path,PATH_VIDEO_FPS,(canvas_w,canvas_h))
    steps = PATH_VIDEO_DURATION_SEC * PATH_VIDEO_FPS
    try:
        for index in range(steps):
            frame = trail.advance(PATH_VIDEO_DURATION_SEC*index/max(1,steps-1), labels=False)
            writer.write(frame)
            if on_frame:
                on_frame(index+1,steps)
    finally:
        writer.release()


# ============================================================
#  Video gabungan multi-kamera: grid semua kamera (ID global) + panel BEV fusion.
# ============================================================

def _gid_color(gid):
    rng = np.random.RandomState(int(gid) % 9973)
    return tuple(int(v) for v in rng.randint(60, 230, size=3))


def _draw_global_boxes(frame, boxes, cam_idx, cam_to_global, identity_confidence, thickness=4):
    for box in boxes:
        tid, x1, y1, x2, y2 = box[:5]
        _gid, label, c = _identity_label(cam_idx, tid, cam_to_global, identity_confidence)
        cv2.rectangle(frame, (int(x1), int(y1)), (int(x2), int(y2)), c, thickness)
        cv2.putText(frame, label, (int(x1), max(12, int(y1) - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, BOX_LABEL_FONT_SCALE, c, 1)


def _bev_cell(global_tracks, venue, t, w, h, bg=None):
    if bg is not None:
        canvas = (bg.astype(np.float32) * 0.45).astype(np.uint8)   # denah digelapkan
    else:
        canvas = np.full((h, w, 3), 12, np.uint8)                  # nyaris hitam
    W, Hm = float(venue.widthM), float(venue.heightM)

    def to_px(x, y):
        return (int(np.clip(x / W, 0, 1) * (w - 1)), int(np.clip(y / Hm, 0, 1) * (h - 1)))

    for gid, obs in global_tracks.items():
        pts = [to_px(x, y) for (tt, x, y) in obs if tt <= t]
        if not pts:
            continue
        c = _gid_color(gid)
        for k in range(1, len(pts)):
            cv2.line(canvas, pts[k - 1], pts[k], c, 1)
        cv2.circle(canvas, pts[-1], 3, c, -1)
        cv2.putText(canvas, str(gid), (pts[-1][0] + 3, pts[-1][1]),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.35, c, 1)
    cv2.putText(canvas, "BEV (fusion)", (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (240, 240, 240), 2)
    return canvas


def render_combined_video(cams, cam_det, cam_render, cam_to_global, identity_confidence,
                          global_tracks, venue, cfg,
                          out_path, cell_w=480, cell_h=270, bg_path=None, privacy=None, on_frame=None):
    """
    Susun semua kamera (ID global) dalam grid + satu panel BEV fusion -> 1 video.
    Frame antar kamera disinkronkan per langkah waktu (relatif ke start trim).
    """
    from .privacy import PersonPrivacy
    privacy = privacy or PersonPrivacy(cfg.DEVICE)
    n = len(cams)
    if n == 0:
        return

    readers = []
    for i, c in enumerate(cams):
        det = cam_det[i]
        fps = det["fps"] or 30.0
        source_start = camera_source_start(c)
        start_frame = max(0, int(source_start * fps))
        proc = [fi for (fi, _t, _b) in det["dets"]]      # frame yang diproses (urut waktu)
        cap = cv2.VideoCapture(c.videoPath)
        seek_accurate(cap, start_frame)
        readers.append({"cap": cap, "proc": proc, "pos": start_frame,
                        "per_frame": cam_render[i]["per_frame"], "idx": i, "label": c.label})

    steps = min((len(r["proc"]) for r in readers), default=0)
    if steps == 0:
        for r in readers:
            r["cap"].release()
        return

    n_panels = n + 1                                     # kamera + BEV
    cols = int(math.ceil(math.sqrt(n_panels)))
    rows = int(math.ceil(n_panels / cols))
    out_w, out_h = cols * cell_w, rows * cell_h
    vw = _open_writer(out_path, cfg.PROC_FPS, (out_w, out_h))
    bev_bg = _load_bg(bg_path, cell_w, cell_h)           # floor map untuk panel BEV (sekali)

    bev_background = ((bev_bg.astype(np.float32)*0.45).astype(np.uint8) if bev_bg is not None
                      else np.full((cell_h,cell_w,3),12,np.uint8))
    trail = TrailRenderer(global_tracks, venue, cell_w, cell_h, bev_background)
    try:
        for k in range(steps):
            t = k / cfg.PROC_FPS
            frames = []
            for r in readers:
                target = r["proc"][k]
                while r["pos"] < target:
                    if not r["cap"].grab():
                        raise RuntimeError("Video ended before scheduled frame")
                    r["pos"] += 1
                ok, frame = r["cap"].read()
                r["pos"] += 1
                if not ok:
                    raise RuntimeError("Video frame unavailable during privacy rendering")
                frames.append(frame)
            redacted = privacy.redact_batch(frames)
            cells = []
            for r, frame in zip(readers, redacted):
                sx, sy = cell_w/frame.shape[1], cell_h/frame.shape[0]
                boxes = [(box[0],box[1]*sx,box[2]*sy,box[3]*sx,box[4]*sy)
                         for box in r["per_frame"].get(r["proc"][k], [])]
                frame = cv2.resize(frame, (cell_w,cell_h))
                _draw_global_boxes(frame, boxes, r["idx"], cam_to_global, identity_confidence, thickness=3)
                cv2.putText(frame,f"C{r['idx']+1}",(8,22),cv2.FONT_HERSHEY_SIMPLEX,0.7,(255,255,255),2)
                cells.append(frame)
            bev = trail.advance(t, labels=True)
            cv2.putText(bev,"BEV (fusion)",(8,22),cv2.FONT_HERSHEY_SIMPLEX,0.6,(240,240,240),2)
            cells.append(bev)

            canvas = np.zeros((out_h, out_w, 3), np.uint8)
            for p, cell in enumerate(cells):
                rr, cc = divmod(p, cols)
                canvas[rr * cell_h:(rr + 1) * cell_h, cc * cell_w:(cc + 1) * cell_w] = cell
            vw.write(canvas)
            if on_frame:
                on_frame(k+1,steps)

    finally:
        for r in readers:
            r["cap"].release()
        vw.release()
