"""
Tahap RENDER: hasilkan artifact yang ditampilkan di layar Hasil.
- heatmap.png       : bird's-eye heatmap
- camN_boxes.mp4    : video deteksi + bounding box + ID global + titik kaki
- paths.mp4         : simulasi jalur di bidang lantai
Video adalah bagian termahal; bisa dimatikan lewat options.renderVideos.
"""
import os
import shutil
import subprocess
import math
import numpy as np
import cv2

from .detect import seek_accurate

def _open_writer(path, fps, size):
    # mp4v = frame benar & andal di OpenCV. (avc1 di macOS sering korup/hijau.)
    return cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, size)


def _transcode_h264(path):
    """Kalau ffmpeg tersedia, ubah ke H.264 (yuv420p) supaya bisa diputar di browser."""
    ff = shutil.which("ffmpeg")
    if not ff:
        return
    src = str(path)
    tmp = src + ".h264.mp4"
    try:
        r = subprocess.run(
            [ff, "-y", "-i", src, "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", "-loglevel", "error", tmp],
            timeout=1800,
        )
        if r.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
            os.replace(tmp, src)
        elif os.path.exists(tmp):
            os.remove(tmp)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass


def render_heatmap(heat: np.ndarray, out_path, out_w: int = 720):
    gh, gw = heat.shape
    norm = heat / heat.max() if heat.max() > 0 else heat
    small = (norm * 255).astype(np.uint8)
    out_h = max(1, int(out_w * gh / max(gw, 1)))
    big = cv2.resize(small, (out_w, out_h), interpolation=cv2.INTER_LINEAR)
    big = cv2.GaussianBlur(big, (0, 0), sigmaX=out_w / 90.0)
    color = cv2.applyColorMap(big, cv2.COLORMAP_TURBO)
    color[big < 8] = (36, 21, 15)  # area sepi -> gelap
    cv2.imwrite(str(out_path), color)


def render_bbox_video(video_path, cam_info, cam_to_global, cam_idx, cfg, out_path):
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
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if idx > max_fi:
            break
        if idx in fset:
            for (tid, x1, y1, x2, y2) in per_frame[idx]:
                gid = cam_to_global.get((cam_idx, tid), tid)
                p1, p2 = (int(x1), int(y1)), (int(x2), int(y2))
                cv2.rectangle(frame, p1, p2, (214, 87, 84), 2)          # BGR ~ indigo
                cv2.putText(frame, f"ID {gid}", (int(x1), int(y1) - 6),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (214, 87, 84), 2)
                cv2.circle(frame, (int((x1 + x2) / 2), int(y2)), 4, (0, 165, 255), -1)  # titik kaki
            vw.write(frame)
        idx += 1
    cap.release()
    vw.release()
    _transcode_h264(out_path)


def render_path_video(global_tracks, venue, cfg, out_path, canvas_w: int = 900):
    W, Hm = float(venue.widthM), float(venue.heightM)
    canvas_h = max(1, int(canvas_w * Hm / max(W, 1e-6)))

    allt = [o[0] for obs in global_tracks.values() for o in obs]
    if not allt:
        return
    tmin, tmax = min(allt), max(allt)
    binsec = 1.0 / cfg.PROC_FPS
    nb = int((tmax - tmin) / binsec) + 1

    def to_px(x, y):
        return (int(np.clip(x / W, 0, 1) * canvas_w), int(np.clip(y / Hm, 0, 1) * canvas_h))

    tracks = {g: sorted(o) for g, o in global_tracks.items()}
    colors = {}
    for g in tracks:
        rng = np.random.RandomState(int(g) % 9973)
        colors[g] = tuple(int(v) for v in rng.randint(60, 230, size=3))

    vw = _open_writer(out_path, cfg.PROC_FPS, (canvas_w, canvas_h))
    trail = np.full((canvas_h, canvas_w, 3), 245, np.uint8)
    for b in range(nb):
        t = tmin + b * binsec
        frame = trail.copy()
        for g, obs in tracks.items():
            pts = [to_px(x, y) for (tt, x, y) in obs if tt <= t]
            for k in range(1, len(pts)):
                cv2.line(trail, pts[k - 1], pts[k], colors[g], 2)      # jejak permanen
            if pts:
                cv2.circle(frame, pts[-1], 5, colors[g], -1)           # posisi saat ini
        vw.write(frame)
    vw.release()
    _transcode_h264(out_path)


# ============================================================
#  Video gabungan multi-kamera: grid semua kamera (ID global) + panel BEV fusion.
# ============================================================

def _gid_color(gid):
    rng = np.random.RandomState(int(gid) % 9973)
    return tuple(int(v) for v in rng.randint(60, 230, size=3))


def _draw_global_boxes(frame, boxes, cam_idx, cam_to_global):
    for (tid, x1, y1, x2, y2) in boxes:
        gid = cam_to_global.get((cam_idx, tid), tid)
        c = _gid_color(gid)
        cv2.rectangle(frame, (int(x1), int(y1)), (int(x2), int(y2)), c, 2)
        cv2.putText(frame, f"ID {gid}", (int(x1), max(12, int(y1) - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, c, 1)


def _bev_cell(global_tracks, venue, t, w, h):
    canvas = np.full((h, w, 3), 12, np.uint8)      # nyaris hitam
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


def render_combined_video(cams, cam_det, cam_render, cam_to_global, global_tracks, venue, cfg,
                          out_path, cell_w=480, cell_h=270):
    """
    Susun semua kamera (ID global) dalam grid + satu panel BEV fusion -> 1 video.
    Frame antar kamera disinkronkan per langkah waktu (relatif ke start trim).
    """
    n = len(cams)
    if n == 0:
        return

    readers = []
    for i, c in enumerate(cams):
        det = cam_det[i]
        fps = det["fps"] or 30.0
        start_frame = max(0, int(getattr(c, "startSec", 0.0) * fps))
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

    for k in range(steps):
        t = k / cfg.PROC_FPS
        cells = []
        for r in readers:
            target = r["proc"][k]
            while r["pos"] < target:                     # maju ke frame target (grab cepat)
                if not r["cap"].grab():
                    break
                r["pos"] += 1
            ok, frame = r["cap"].read()
            r["pos"] += 1
            if not ok or frame is None:
                frame = np.zeros((cell_h, cell_w, 3), np.uint8)
            else:
                _draw_global_boxes(frame, r["per_frame"].get(target, []), r["idx"], cam_to_global)
                frame = cv2.resize(frame, (cell_w, cell_h))
            cv2.putText(frame, f"C{r['idx'] + 1}", (8, 22),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
            cells.append(frame)

        cells.append(_bev_cell(global_tracks, venue, t, cell_w, cell_h))

        canvas = np.zeros((out_h, out_w, 3), np.uint8)
        for p, cell in enumerate(cells):
            rr, cc = divmod(p, cols)
            canvas[rr * cell_h:(rr + 1) * cell_h, cc * cell_w:(cc + 1) * cell_w] = cell
        vw.write(canvas)

    for r in readers:
        r["cap"].release()
    vw.release()
    _transcode_h264(out_path)