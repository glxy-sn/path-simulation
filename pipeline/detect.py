"""
Tahap DETEKSI: jalankan YOLO over frame video, kumpulkan bounding box orang.
Deteksi di-BATCH (beberapa frame sekaligus) supaya jauh lebih efisien di MPS
dibanding satu-per-satu. Mendukung trim window [start_sec, start_sec+duration).
"""
import numpy as np
import cv2
from ultralytics import YOLO


def load_model(cfg):
    try:
        import torch
        torch.set_num_threads(1)     # hindari over-subscription thread (segfault/lambat)
    except Exception:
        pass
    return YOLO(cfg.YOLO_MODEL)


def seek_accurate(cap, target_frame):
    """
    Seek FRAME-AKURAT. cap.set(POS_FRAMES) sendiri sering meleset ke keyframe
    terdekat (video terkompresi), bikin trim & overlay tidak sesuai slider.
    Di sini: lompat cepat ke dekat target, lalu maju frame-per-frame (grab) sampai tepat.
    Setelah dipanggil, cap.read() berikutnya = tepat frame `target_frame`.
    """
    target = int(target_frame)
    if target <= 0:
        return
    approx = max(0, target - 120)
    cap.set(cv2.CAP_PROP_POS_FRAMES, approx)
    pos = int(cap.get(cv2.CAP_PROP_POS_FRAMES) or approx)
    if pos > target:                 # seek malah kelewat -> mulai dari awal
        cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        pos = 0
    while pos < target:
        if not cap.grab():
            break
        pos += 1


def _boxes_from_result(res):
    if res.boxes is None or not len(res.boxes):
        return np.empty((0, 5), dtype=np.float32)
    xyxy = res.boxes.xyxy.cpu().numpy().astype(np.float32)
    conf = res.boxes.conf.cpu().numpy().reshape(-1, 1).astype(np.float32)

    # Clamp ke dalam frame + buang box degenerate (crop kosong -> OSNet bisa crash native).
    h, w = res.orig_shape          # (tinggi, lebar)
    xyxy[:, 0] = np.clip(xyxy[:, 0], 0, w - 1)
    xyxy[:, 2] = np.clip(xyxy[:, 2], 0, w - 1)
    xyxy[:, 1] = np.clip(xyxy[:, 1], 0, h - 1)
    xyxy[:, 3] = np.clip(xyxy[:, 3], 0, h - 1)
    bw = xyxy[:, 2] - xyxy[:, 0]
    bh = xyxy[:, 3] - xyxy[:, 1]
    keep = (bw >= 3) & (bh >= 3)
    return np.hstack([xyxy, conf])[keep]


def detect_video(model, video_path: str, cfg, on_frame=None,
                 start_sec: float = 0.0, duration_sec=None) -> dict:
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Tidak bisa membuka video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    frame_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    frame_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    stride = max(1, round(fps / cfg.PROC_FPS))

    # jendela [start_frame, end_frame)
    dur = duration_sec if (duration_sec is not None and duration_sec > 0) \
        else getattr(cfg, "MAX_DURATION_SEC", 0)
    start_frame = max(0, int(start_sec * fps))
    if dur and dur > 0:
        end_frame = start_frame + int(dur * fps)
    else:
        end_frame = total if total else None
    if total and end_frame:
        end_frame = min(end_frame, total)

    span = (end_frame - start_frame) if end_frame else 0
    to_process = max(1, span // stride) if span else 0

    seek_accurate(cap, start_frame)   # frame-akurat (bukan lompat ke keyframe terdekat)

    batch_size = max(1, getattr(cfg, "BATCH_SIZE", 8))
    dets = []
    done = 0
    buf_frames, buf_meta = [], []

    def flush():
        nonlocal done
        if not buf_frames:
            return
        results = model.predict(
            buf_frames,
            imgsz=cfg.IMGSZ, conf=cfg.CONF, iou=cfg.IOU,
            classes=[cfg.PERSON_CLASS], device=cfg.DEVICE, verbose=False,
        )
        for (fi, t_rel), res in zip(buf_meta, results):
            dets.append((fi, t_rel, _boxes_from_result(res)))
            done += 1
            if on_frame:
                on_frame(done, to_process)
        buf_frames.clear()
        buf_meta.clear()

    idx = start_frame
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if end_frame and idx >= end_frame:
            break
        if (idx - start_frame) % stride == 0:
            buf_frames.append(frame)
            buf_meta.append((idx, (idx - start_frame) / fps))
            if len(buf_frames) >= batch_size:
                flush()
        idx += 1
    flush()

    cap.release()
    return {
        "fps": fps, "total": total, "stride": stride,
        "frame_w": frame_w, "frame_h": frame_h, "dets": dets,
    }