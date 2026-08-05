"""CrowdFlow — deteksi + pelacakan orang, dua fungsi untuk dipanggil dari kode lain.

Dipakai kalau kamu tidak mau menjalankan jalankan.py, cukup menempelkan ke kode
sendiri:

    from crowdflow import buat_pipeline, lacak

    det, trk = buat_pipeline()                 # sekali di awal
    for frame in video:
        hasil = lacak(det, trk, frame)         # tiap frame
        # hasil: array (N, 8) -> x1, y1, x2, y2, id, conf, cls, idx

Butuh: pip install ultralytics boxmot
Bobot detektor `weights/yolo11s_crowd.pt` harus ada di sebelah berkas ini.
Model Re-ID terunduh otomatis saat pertama dipanggil (~17 MB).
"""
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
DETEKTOR = HERE / "weights/yolo11s_crowd.pt"

# Bobot bawaan BoxMOT — tidak perlu berkas, terunduh sendiri. Fine-tune di domain
# pantry sudah dicoba dua kali dan tidak terbukti membaik; lihat notebook bagian 4.
REID = "osnet_ain_x1_0_msmt17.pt"

# --- setelan detektor -----------------------------------------------------
# conf 0,25 bukan 0,50. Diuji terhadap 106 anotasi manusia:
#     conf 0,50 -> recall 0,509
#     conf 0,25 -> recall 0,821, presisi 0,906
# Di 0,50, separuh pengunjung yang duduk tidak pernah terdeteksi.
CONF, IMGSZ, IOU_NMS = 0.25, 1280, 0.7

# --- setelan tracker ------------------------------------------------------
# Ketiga ambang track disamakan dengan conf detektor. Nilai bawaan BoTSORT
# (0,50 / 0,60) membuat tracker hanya melahirkan ID untuk deteksi di atas 0,60,
# sehingga manfaat conf 0,25 terbuang: 15,9 deteksi/frame jadi 9,6 track.
#
# proximity_thresh 0,9 dan appearance_thresh 0,6 adalah tuas TERPENTING di
# seluruh sistem. Membuka dari bawaan 0,5/0,25 menaikkan IDF1 sepuluh poin
# (39,0 -> 49,8); mengganti model Re-ID hanya menggeser satu poin.
BOTSORT = dict(
    track_high_thresh=0.25, track_low_thresh=0.25, new_track_thresh=0.25,
    track_buffer=60, match_thresh=0.8,
    proximity_thresh=0.9, appearance_thresh=0.6,
    use_cmc=True, cmc_method="sof", with_reid=True,
)


def perangkat():
    import torch
    if torch.backends.mps.is_available():
        return "mps"
    return "cuda" if torch.cuda.is_available() else "cpu"


def buat_pipeline(device=None):
    """Kembalikan (detektor, tracker) siap pakai. Panggil SEKALI di awal.

    Tracker menyimpan keadaan antar frame, jadi satu tracker untuk satu video.
    Kalau memproses beberapa kamera, buat tracker terpisah per kamera.
    """
    from ultralytics import YOLO
    from boxmot.trackers.bbox.botsort import BotSort
    from boxmot.reid.core.reid import ReID

    if not DETEKTOR.exists():
        raise FileNotFoundError(f"bobot detektor tidak ada: {DETEKTOR}")
    dev = device or perangkat()
    det = YOLO(str(DETEKTOR))
    ext = ReID(REID, device=dev, half=False).model
    return det, BotSort(reid_model=ext, **BOTSORT)


def lacak(det, trk, img):
    """Proses satu frame BGR (dari cv2). Kembalikan array (N, 8).

    Kolom: x1, y1, x2, y2, id, conf, cls, idx — sama seperti keluaran BoxMOT.
    Panggil berurutan sesuai urutan frame; tracker bergantung pada riwayat.
    """
    r = det.predict(img, classes=[0], conf=CONF, iou=IOU_NMS, imgsz=IMGSZ,
                    verbose=False)[0]
    if r.boxes is None or not len(r.boxes):
        d = np.empty((0, 6))
    else:
        d = np.column_stack([r.boxes.xyxy.cpu().numpy(),
                             r.boxes.conf.cpu().numpy(),
                             np.zeros(len(r.boxes))])
    return np.asarray(trk.update(d, img)).reshape(-1, 8)


if __name__ == "__main__":
    import sys
    import cv2

    if len(sys.argv) < 2:
        sys.exit("pakai: python crowdflow.py video.mp4")
    det, trk = buat_pipeline()
    cap = cv2.VideoCapture(sys.argv[1])
    for i in range(30):
        ok, img = cap.read()
        if not ok:
            break
        hasil = lacak(det, trk, img)
        if i % 10 == 0:
            print(f"frame {i}: {len(hasil)} orang, id {[int(x) for x in hasil[:, 4]]}")
    cap.release()
