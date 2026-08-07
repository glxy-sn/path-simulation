"""
Homografi dari kalibrasi 4-titik yang dikumpulkan app.

Bedanya dari WILDTRACK: di sana kamu punya kalibrasi kamera lengkap (intrinsic +
extrinsic). Di app, user cuma klik 4 titik di frame + 4 titik yang bersesuaian di
denah/canvas. Dari 4 pasang titik itu kita hitung homografi piksel -> meter.
"""
import numpy as np
import cv2


def homography_pixel_to_meter(image_points, plane_points,
                              frame_w: int, frame_h: int,
                              venue_w: float, venue_h: float):
    """
    image_points / plane_points: list[Point] ternormalisasi 0–1 (4 titik).
    - image_points denormalisasi ke piksel pakai resolusi video (frame_w, frame_h).
    - plane_points denormalisasi ke meter pakai dimensi venue (venue_w, venue_h).
    Return matriks H 3x3 (float32) yang memetakan piksel gambar -> meter di lantai.
    """
    src = np.array([[p.x * frame_w, p.y * frame_h] for p in image_points], dtype=np.float32)
    dst = np.array([[p.x * venue_w, p.y * venue_h] for p in plane_points], dtype=np.float32)
    if len(src) == 4:
        return cv2.getPerspectiveTransform(src, dst)          # 4 titik: solusi eksak
    H, _ = cv2.findHomography(src, dst, 0)                     # 4–8 titik: least-squares
    if H is None:
        return cv2.getPerspectiveTransform(src[:4], dst[:4])  # fallback
    return H


def project_points(H, pts) -> np.ndarray:
    """pts: Nx2 piksel -> Nx2 meter di lantai."""
    pts = np.asarray(pts, dtype=np.float32)
    if pts.size == 0:
        return np.empty((0, 2), dtype=np.float32)
    out = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), H)
    return out.reshape(-1, 2)