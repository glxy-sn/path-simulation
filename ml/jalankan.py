"""CrowdFlow — deteksi + pelacakan orang dari rekaman CCTV, satu berkas.

Semua setelan di sini BUKAN nilai bawaan. Tiap angka hasil pengukuran; alasannya
ada di komentar masing-masing dan di CATATAN.md.

    python jalankan.py video.mp4
    python jalankan.py video.mp4 --mulai 600 --frame 1500 --keluar hasil.mp4
"""
import argparse
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).parent
DETEKTOR = HERE / "weights/yolo11s_crowd.pt"
# Bobot bawaan BoxMOT — TIDAK perlu berkas, terunduh otomatis (~17 MB) saat
# pertama dipanggil. Fine-tune di domain pantry sudah dicoba dua kali dan tidak
# terbukti membaik; rinciannya di 4_penerapan_pantry.ipynb bagian 4.
REID = "osnet_ain_x1_0_msmt17.pt"

# --- detektor -------------------------------------------------------------
# conf 0,25 bukan 0,50. Diuji terhadap 106 anotasi manusia di pantry:
#     conf 0,50 -> recall 0,509
#     conf 0,25 -> recall 0,821, presisi 0,906
# Di 0,50, separuh pengunjung yang duduk tidak pernah terdeteksi.
CONF, IMGSZ, IOU_NMS = 0.25, 1280, 0.7

# --- tracker --------------------------------------------------------------
# Ketiga ambang track disamakan dengan conf detektor. Nilai bawaan BoTSORT
# (0,50 / 0,60) membuat tracker hanya melahirkan ID untuk deteksi di atas 0,60,
# sehingga manfaat conf 0,25 terbuang di tahap berikutnya: 15,9 deteksi/frame
# hanya menjadi 9,6 track. Setelah diselaraskan: 15,5.
#
# proximity_thresh 0,9 dan appearance_thresh 0,6 adalah tuas TERPENTING di
# seluruh sistem. Membuka dari nilai bawaan 0,5/0,25 menaikkan IDF1 sepuluh poin
# (39,0 -> 49,8). Sebagai pembanding, mengganti model Re-ID hanya menggeser satu
# poin. Kalau hanya satu hal yang bisa dibawa dari catatan ini, bawa yang ini.
BOTSORT = dict(
    track_high_thresh=0.25, track_low_thresh=0.25, new_track_thresh=0.25,
    track_buffer=60, match_thresh=0.8,
    proximity_thresh=0.9, appearance_thresh=0.6,
    use_cmc=True, cmc_method="sof", with_reid=True,
)

# Kotak ditahan sesaat ketika orang hilang sekejap: skor deteksi orang yang
# setengah tertutup bergoyang di sekitar ambang, jadi kotaknya berkedip padahal
# orangnya tidak ke mana-mana. Yang ditahan digambar pudar supaya jujur.
TAHAN = 5


def warna_id(i):
    rng = np.random.default_rng(int(i) * 9973 + 1)
    return tuple(int(x) for x in rng.integers(60, 245, 3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--mulai", type=int, default=0, help="detik mulai")
    ap.add_argument("--frame", type=int, default=600, help="jumlah frame diproses")
    ap.add_argument("--keluar", default="keluaran.mp4")
    ap.add_argument("--skala", type=float, default=0.5)
    a = ap.parse_args()

    if not DETEKTOR.exists():
        sys.exit(f"bobot detektor tidak ada: {DETEKTOR}")
    if not Path(a.video).exists():
        sys.exit(f"video tidak ada: {a.video}")

    import torch
    from ultralytics import YOLO
    from boxmot.trackers.bbox.botsort import BotSort
    from boxmot.reid.core.reid import ReID

    dev = "mps" if torch.backends.mps.is_available() else (
        "cuda" if torch.cuda.is_available() else "cpu")
    print(f"perangkat: {dev}")

    det = YOLO(str(DETEKTOR))
    # Nama berkas Re-ID WAJIB diawali nama arsitektur yang dikenal BoxMOT
    # (osnet_ain_x1_0_...). BoxMOT menebak arsitektur dari nama, bukan dari isi;
    # nama lain ditolak dengan KeyError: Unknown model 'None'.
    ext = ReID(REID, device=dev, half=False).model
    trk = BotSort(reid_model=ext, **BOTSORT)

    cap = cv2.VideoCapture(a.video)
    cap.set(cv2.CAP_PROP_POS_MSEC, a.mulai * 1000)
    vw, ingat = None, {}

    for i in range(a.frame):
        ok, img = cap.read()
        if not ok:
            break
        r = det.predict(img, classes=[0], conf=CONF, iou=IOU_NMS, imgsz=IMGSZ,
                        verbose=False)[0]
        if r.boxes is None or not len(r.boxes):
            d = np.empty((0, 6))
        else:
            b = r.boxes.xyxy.cpu().numpy()
            s = r.boxes.conf.cpu().numpy()
            d = np.column_stack([b, s, np.zeros(len(b))])
        res = np.asarray(trk.update(d, img)).reshape(-1, 8)

        kini = {int(x[4]) for x in res}
        gambar = [(x[0], x[1], x[2], x[3], int(x[4]), False) for x in res]
        for tid in list(ingat):
            if tid in kini:
                del ingat[tid]
        for tid, (kotak, sisa) in list(ingat.items()):
            if sisa <= 0:
                del ingat[tid]
            else:
                ingat[tid] = (kotak, sisa - 1)
                gambar.append((*kotak, tid, True))
        for x in res:
            ingat[int(x[4])] = ((x[0], x[1], x[2], x[3]), TAHAN)

        p = img.copy()
        for x1, y1, x2, y2, tid, pudar in gambar:
            c = warna_id(tid)
            if pudar:
                c = tuple(int(v * 0.55 + 110) for v in c)
            cv2.rectangle(p, (int(x1), int(y1)), (int(x2), int(y2)), c, 3)
            t = str(tid)
            (tw, th), _ = cv2.getTextSize(t, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
            cv2.rectangle(p, (int(x1), max(0, int(y1) - th - 9)),
                          (int(x1) + tw + 9, int(y1)), c, -1)
            cv2.putText(p, t, (int(x1) + 4, max(th, int(y1) - 5)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2, cv2.LINE_AA)

        p = cv2.resize(p, None, fx=a.skala, fy=a.skala)
        cv2.rectangle(p, (0, 0), (p.shape[1], 62), (250, 250, 250), -1)
        cv2.putText(p, f"{len(res)} orang terdeteksi", (14, 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (25, 25, 25), 2, cv2.LINE_AA)

        if vw is None:
            h, w = p.shape[:2]
            vw = cv2.VideoWriter(a.keluar, cv2.VideoWriter_fourcc(*"mp4v"), 20, (w, h))
        vw.write(p)
        if (i + 1) % 100 == 0:
            print(f"  {i + 1}/{a.frame}", flush=True)

    cap.release()
    if vw:
        vw.release()
    print("tersimpan:", a.keluar)


if __name__ == "__main__":
    main()
