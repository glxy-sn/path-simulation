"""Video pipeline final DUA KAMERA: apakah ID orang sama di kamera 1 dan 2?

Beda dengan `viz_pipeline_final.py` yang cuma satu panel: di sini kedua sisi
kamera pantry dijalankan berdampingan, lalu track dari kamera 2 DICOCOKKAN ke
track kamera 1 memakai embedding CLIP-ReID, sehingga orang yang sama mendapat
nomor dan warna yang sama di kedua panel.

Setelan detektor mengikuti kesimpulan notebook 1 (conf 0,25). Ambang tracker
SENGAJA diturunkan menyesuaikan conf detektor:

    track_high_thresh 0,50 -> 0,25
    new_track_thresh  0,60 -> 0,25

Dengan ambang lama, BoTSORT hanya melahirkan track untuk deteksi di atas 0,60,
jadi ~40% deteksi (justru orang yang duduk/tertutup — persis yang mau ditangkap
dengan conf 0,25) tidak pernah dapat kotak. Diukur di 120 frame day1cam1 pada
detik 10800: 15,9 deteksi/frame -> 9,6 track dengan ambang lama, 15,5 dengan
ambang baru.

BATAS PENTING: video pantry TIDAK punya ground truth dan kedua kamera TIDAK
punya homografi bersama, jadi pencocokan lintas kamera di sini murni penampilan
dan TIDAK bisa dibuktikan benar. Angka "N cocok lintas kamera" adalah klaim
model, bukan hasil terverifikasi — kotak putus-putus dipakai untuk menandainya
supaya bisa diperiksa mata.

    ../venv_boxmot/bin/python experiments/viz_pipeline_2kamera.py
    ../venv_boxmot/bin/python experiments/viz_pipeline_2kamera.py --render-saja
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np
from scipy.optimize import linear_sum_assignment

APP = Path(__file__).parent.parent
sys.path.insert(0, str(APP))
sys.path.insert(0, str(APP / "reid"))
os.chdir(APP)

CH = APP.parent
DETECTOR = APP / "weights_ft/yolo11s_crowd.pt"
CONF, IMGSZ, IOU_NMS = 0.25, 1280, 0.7

# Ambang tracker diselaraskan dengan CONF detektor (lihat docstring).
# appearance_thresh = JARAK embedding maksimum yang diterima
# (botsort.py: `emb_dists[emb_dists > appearance_thresh] = 1.0`), jadi 0,60
# berarti kemiripan >= 0,40. Makin besar = makin longgar.
#
# Dipilih dari sapuan di pantry (experiments/sapu_appearance_pantry.py,
# 600 frame kamera 1, deteksi identik):
#     0,25 -> 62 ID, median 3,0 dtk
#     0,40 -> 50 ID, median 3,5 dtk     (nilai lama)
#     0,60 -> 48 ID, median 4,2 dtk     <- dipakai
#     0,75 -> 48 ID, median 4,2 dtk     (identik: penampilan tidak menyaring lagi)
#
# Bahwa 0,60 dan 0,75 memberi hasil sama persis berarti di titik itu penampilan
# sudah meloloskan semua pasangan. Jadi manfaatnya di sini bukan dari kemampuan
# MEMBEDAKAN, melainkan dari TIDAK MENGHALANGI: ambang ketat menolak banyak
# pasangan yang sebenarnya benar. Di dalam satu kamera, posisi dan gerak sudah
# menyelesaikan sebagian besar pekerjaan sebelum penampilan sempat berbicara.
BOTSORT = dict(track_high_thresh=0.25, track_low_thresh=0.25, new_track_thresh=0.25,
               track_buffer=60, match_thresh=0.8,
               proximity_thresh=0.9, appearance_thresh=0.60,
               use_cmc=True, cmc_method="sof", with_reid=True)

KAMERA = {1: CH / "videos/day1cam1.mp4", 2: CH / "videos/day1cam2.mp4"}
# 11:48 — ramp paling curam sepanjang hari (+14 orang dalam 5 menit, dari
# reid/hasil_okupansi_pantry.csv). Dipilih karena ISINYA: orang berdatangan
# membawa makanan, memilih kursi, lalu duduk, sementara yang sudah duduk tetap
# di tempat dan sebagian lalu-lalang. Jam 12:10 lebih ramai tapi lebih statis —
# hampir semua orang sudah duduk, jadi tidak ada yang menarik untuk dilihat.
MULAI_DETIK = 9600      # kedua kamera diasumsikan sinkron waktu
JUMLAH = 1500           # 1500 frame @ 20 fps = 75 detik, kecepatan nyata
# Kecepatan asli. Mempercepat sempat dicoba untuk menghemat render, tapi memilih
# POTONGAN yang isinya menarik jauh lebih baik daripada mempercepat potongan yang
# membosankan — orang duduk yang dipercepat tetap orang duduk.
LANGKAH = 1
FPS_OUT = 20            # sama dengan fps sumber -> kecepatan nyata
SKALA = 0.52            # 2 panel 2304x1296 -> ~2396 px lebar total
# Kotak ditahan sebentar saat orang hilang sekejap. Skor deteksi orang yang
# setengah tertutup bergoyang di sekitar ambang 0,25, jadi kotaknya berkedip
# padahal orangnya tidak ke mana-mana. Kotak yang ditahan digambar PUDAR supaya
# jelas itu posisi terakhir yang diketahui, bukan deteksi baru.
TAHAN = 5               # frame diproses (~0,5 detik pada 10 fps efektif)

# Pencocokan lintas kamera
EMB_TIAP = 5            # ambil embedding tiap N frame per track (hemat waktu)
MIN_PANJANG = 10        # track lebih pendek dari ini tidak ikut dicocokkan
AMBANG_SILANG = float(os.environ.get("SILANG_AMBANG", 0.75))

CACHE = APP / "pipeline_2kamera_tracks.json"


def warna_id(i):
    """Warna tetap per nomor ID — ID switch terlihat sebagai perubahan warna."""
    rng = np.random.default_rng(int(i) * 9973 + 1)
    return tuple(int(x) for x in rng.integers(60, 245, 3))


def baca_frame(lokasi, n):
    cap = cv2.VideoCapture(str(lokasi))
    cap.set(cv2.CAP_PROP_POS_MSEC, MULAI_DETIK * 1000)
    diambil = 0
    while diambil < n:
        ok, f = cap.read()
        if not ok:
            break
        for _ in range(LANGKAH - 1):        # lewati frame antara
            cap.read()
        diambil += 1
        yield f
    cap.release()


def lacak_satu_kamera(cam, det, ext, BotSort, dev=None):
    """Jalankan detektor + tracker di satu kamera.

    Kembalikan (per_frame, galeri):
        per_frame[i] = list (x1, y1, x2, y2, track_id)
        galeri[track_id] = embedding rata-rata (L2-normalized)
    """
    trk = BotSort(reid_model=ext, **BOTSORT)
    per_frame, kumpul = [], {}
    t0 = time.time()
    for i, img in enumerate(baca_frame(KAMERA[cam], JUMLAH)):
        # `device=dev` disebut dengan sengaja — lihat catatan panjang di
        # ke_json_aplikasi.py. Tanpa itu, 103 ms/frame; dengan itu, 29 ms,
        # deteksinya sama persis.
        r = det.predict(img, classes=[0], conf=CONF, iou=IOU_NMS, imgsz=IMGSZ,
                        verbose=False, device=dev)[0]
        if r.boxes is None or not len(r.boxes):
            d = np.empty((0, 6))
        else:
            b = r.boxes.xyxy.cpu().numpy()
            s = r.boxes.conf.cpu().numpy()
            d = np.column_stack([b, s, np.zeros(len(b))])
        res = np.asarray(trk.update(d, img)).reshape(-1, 8)
        keluar = [(float(x[0]), float(x[1]), float(x[2]), float(x[3]), int(x[4]))
                  for x in res]
        per_frame.append(keluar)

        # Embedding untuk pencocokan lintas kamera: diambil ulang dari kotak
        # track (bukan dari kotak deteksi) supaya yang dibandingkan benar-benar
        # penampilan orang yang track itu wakili.
        if keluar and i % EMB_TIAP == 0:
            kotak = np.array([k[:4] for k in keluar])
            embs = ext.get_features(kotak, img)
            for (_, _, _, _, tid), e in zip(keluar, embs):
                kumpul.setdefault(tid, []).append(e)

        if (i + 1) % 100 == 0:
            print(f"  C{cam} {i + 1}/{JUMLAH}  ({(i + 1) / (time.time() - t0):.1f} fps)",
                  flush=True)

    galeri = {}
    for tid, es in kumpul.items():
        e = np.mean(es, 0)
        galeri[tid] = e / np.linalg.norm(e)
    return per_frame, galeri


# --- penyambungan track (lihat experiments/sambung_track.py untuk versi lengkap) ---
# Ambang dalam PIKSEL GAMBAR, bukan piksel bird view: di sini kita bekerja langsung
# di koordinat kamera. Nilainya disetarakan dengan jeda 120 frame / jarak 60 px
# yang dipilih lewat sapuan di sana.
# Disapu terhadap anotasi manusia (19 orang di kamera 1, detik 10800, 900 frame).
# Dari 47 ID mentah:
#     jeda  6 dtk / jarak 150 -> 33 ID, durasi median 14,8s   (nilai lama)
#     jeda 12 dtk / jarak 300 -> 24 ID, durasi median 26,1s   <- dipakai
#     jeda 20 dtk / jarak 300 -> 25 ID, durasi median 25,1s   (melandai)
#     jeda 30 dtk / jarak 500 -> 25 ID, durasi median 25,1s
# Melandai setelah 12 detik = yang bisa ditangkap sudah tertangkap, bukan sedang
# menggabungkan sembarangan. 24 ID untuk 19 orang teranotasi masuk akal: selama
# 45 detik ada yang datang dan pergi.
#
# Menaikkan track_buffer BoTSORT tidak menolong (diuji 60..800: identik di atas
# 120). Sebabnya bukan track dibuang terlalu cepat, tapi BoTSORT menolak
# menyambungkannya kembali — pencocokannya dijaga proximity_thresh (IoU), dan
# setelah tertutup lama kotak ramalan Kalman sudah melenceng sehingga IoU nol.
# Penyambungan pasca-tracking di sini tidak terikat gerbang itu.
SAMBUNG_JEDA = 240          # frame (12 detik pada 20 fps)
SAMBUNG_JARAK = 300         # px gambar, ditambah kelonggaran per frame jeda
SAMBUNG_PER_FRAME = 4.0


def sambung_id(per_frame):
    """Satukan fragmen track yang jelas milik orang yang sama.

    Tracker mematikan track begitu orangnya tertutup, lalu memberi ID baru saat
    dia muncul lagi — di pantry ini terjadi 5-6 kali per orang. Di sini fragmen
    yang berakhir dan yang mulai BERDEKATAN dalam waktu dan posisi disatukan.
    Untuk orang duduk buktinya nyaris pasti: dia tidak ke mana-mana.

    Kembalikan peta tid -> tid_wakil.
    """
    ujung = {}      # tid -> [frame_awal, frame_akhir, kaki_awal, kaki_akhir]
    for i, fr in enumerate(per_frame):
        for x1, y1, x2, y2, tid in fr:
            kaki = ((x1 + x2) / 2.0, y2)
            if tid not in ujung:
                ujung[tid] = [i, i, kaki, kaki]
            else:
                ujung[tid][1] = i
                ujung[tid][3] = kaki

    kandidat = []
    for a, (_, akhir_a, _, kaki_a) in ujung.items():
        for b, (mulai_b, _, kaki_b, _) in ujung.items():
            if a == b:
                continue
            jeda = mulai_b - akhir_a
            if jeda <= 0 or jeda > SAMBUNG_JEDA:
                continue
            jarak = ((kaki_b[0] - kaki_a[0]) ** 2 + (kaki_b[1] - kaki_a[1]) ** 2) ** 0.5
            if jarak > SAMBUNG_JARAK + SAMBUNG_PER_FRAME * jeda:
                continue
            kandidat.append((jarak, jeda, a, b))

    kandidat.sort()
    induk = {t: t for t in ujung}

    def cari(x):
        while induk[x] != x:
            induk[x] = induk[induk[x]]
            x = induk[x]
        return x

    pakai_a, pakai_b = set(), set()
    n = 0
    for _, _, a, b in kandidat:
        if a in pakai_a or b in pakai_b or cari(a) == cari(b):
            continue
        induk[cari(b)] = cari(a)
        pakai_a.add(a)
        pakai_b.add(b)
        n += 1
    return {t: cari(t) for t in ujung}, n


def terapkan(per_frame, peta):
    return [[(x1, y1, x2, y2, peta.get(t, t)) for x1, y1, x2, y2, t in fr]
            for fr in per_frame]


def panjang_track(per_frame):
    n = {}
    for fr in per_frame:
        for *_, tid in fr:
            n[tid] = n.get(tid, 0) + 1
    return n


def cocokkan(g1, g2, pj1, pj2):
    """Cocokkan track kamera 2 ke kamera 1 lewat cosine embedding.

    Kembalikan (peta, skor): peta[tid_c2] = tid_c1 untuk pasangan yang diterima.
    """
    a = [t for t in g1 if pj1.get(t, 0) >= MIN_PANJANG]
    b = [t for t in g2 if pj2.get(t, 0) >= MIN_PANJANG]
    if not a or not b:
        return {}, {}
    A = np.stack([g1[t] for t in a])
    B = np.stack([g2[t] for t in b])
    S = A @ B.T                                  # (len(a), len(b)) cosine
    ri, ci = linear_sum_assignment(-S)
    peta, skor = {}, {}
    for r, c in zip(ri, ci):
        if S[r, c] >= AMBANG_SILANG:
            peta[b[c]] = a[r]
            skor[b[c]] = float(S[r, c])
    return peta, skor


def gambar(img, keluar, judul, ditahan=()):
    """Gambar kotak + jumlah orang. `ditahan` = ID yang sedang ditahan (pudar).

    Pencocokan lintas kamera SENGAJA tidak ditampilkan lagi: embedding CLIP-ReID
    tidak punya daya pisah di pantry (orang sama 0,952 vs orang beda 0,919), jadi
    hampir semua pasangan lolos ambang dan angkanya tidak bisa dipertahankan.
    """
    p = img.copy()
    tahan = set(ditahan)
    for x1, y1, x2, y2, tid in keluar:
        gid = int(tid)
        c = warna_id(gid)
        x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
        if gid in tahan:
            # kotak putus-putus: segmen pendek di keempat sisi
            for xa, ya, xb, yb in ((x1, y1, x2, y1), (x1, y2, x2, y2),
                                   (x1, y1, x1, y2), (x2, y1, x2, y2)):
                n = max(2, int(max(abs(xb - xa), abs(yb - ya)) / 12))
                for k in range(0, n, 2):
                    t0, t1 = k / n, min(1.0, (k + 1) / n)
                    cv2.line(p, (int(xa + (xb - xa) * t0), int(ya + (yb - ya) * t0)),
                             (int(xa + (xb - xa) * t1), int(ya + (yb - ya) * t1)),
                             tuple(int(v * 0.55 + 110) for v in c), 3)
        else:
            cv2.rectangle(p, (x1, y1), (x2, y2), c, 3)

        teks = str(gid)
        (tw, th), _ = cv2.getTextSize(teks, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
        cv2.rectangle(p, (x1, max(0, y1 - th - 9)), (x1 + tw + 9, y1), c, -1)
        cv2.putText(p, teks, (x1 + 4, max(th, y1 - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2, cv2.LINE_AA)

    p = cv2.resize(p, None, fx=SKALA, fy=SKALA)
    cv2.rectangle(p, (0, 0), (p.shape[1], 86), (250, 250, 250), -1)
    # OpenCV putText hanya mendukung ASCII; judul sengaja tanpa em-dash.
    cv2.putText(p, judul, (16, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.86, (20, 20, 20), 2,
                cv2.LINE_AA)
    cv2.putText(p, f"{len(keluar)} orang terdeteksi", (16, 68),
                cv2.FONT_HERSHEY_SIMPLEX, 0.82, (30, 30, 30), 2, cv2.LINE_AA)
    return p


def main():
    render_saja = "--render-saja" in sys.argv

    if render_saja and CACHE.exists():
        print("pakai cache:", CACHE)
        c = json.load(open(CACHE))
        pf1 = [[tuple(k) for k in fr] for fr in c["c1"]]
        pf2 = [[tuple(k) for k in fr] for fr in c["c2"]]

    else:
        import torch
        from ultralytics import YOLO
        from boxmot.trackers.bbox.botsort import BotSort
        from boxmot.reid.core.reid import ReID

        for cam, v in KAMERA.items():
            if not Path(v).exists():
                sys.exit(f"video kamera {cam} tidak ada: {v}")

        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        print(f"perangkat {dev}, {JUMLAH} frame x 2 kamera")
        det = YOLO(str(DETECTOR))
        # osnet_ain_x1_0_msmt17 — dipakai SERAGAM di semua skrip visualisasi
        # (viz_lintasan_pantry, viz_heatmap_*) supaya keluarannya bisa
        # disandingkan sebagai satu sistem.
        #
        # Run terkendali 7 kamera, deteksi identik, hanya bobot Re-ID yang berubah
        # (reid/hasil_idf1_pantry_finetune.csv):
        #     osnet_ain_x1_0_msmt17     IDF1 47,37  IDSW 1642  7,60 fps  mAP 19,2
        #     osnet_ain_x1_0_pantry     IDF1 46,97  IDSW 1796 10,14 fps
        #     osnet_ain_x1_0_wildtrack  IDF1 46,54  IDSW 1966  7,68 fps  mAP 21,5
        #     osnet_x0_25_msmt17        IDF1 44,55  IDSW 1753 11,72 fps  mAP  9,1
        #     clipreid                  IDF1 42,05  IDSW 1819  2,90 fps  mAP 49,0
        #
        # Selisih IDF1 di bawah 2,7 poin TIDAK bermakna (simpangan baku antar
        # kamera 3,57 -> galat baku 1,35), jadi empat teratas tak dapat
        # diperingkat. Yang memilih msmt17 di antara mereka: IDSW terendah
        # (1642 vs 1966), data latih paling beragam, dan bobot bawaan BoxMOT
        # sehingga tidak ada berkas yang perlu ikut dikirim.
        #
        # CLIP-ReID: mAP tertinggi (49,0) tapi IDF1 terendah — pembalikan yang
        # jadi temuan utama notebook 3, dan alasan mAP tidak dipakai menilai.
        ext = ReID(str(APP / "reid/weights/osnet_ain_x1_0_msmt17.pt"),
                   device=dev, half=False).model

        pf1, _ = lacak_satu_kamera(1, det, ext, BotSort, dev)
        pf2, _ = lacak_satu_kamera(2, det, ext, BotSort, dev)
        json.dump({"c1": pf1, "c2": pf2}, open(CACHE, "w"))

    # Penyambungan dijalankan SETELAH seluruh rekaman dilacak: butuh melihat
    # fragmen yang muncul belakangan, jadi tidak bisa dikerjakan sambil jalan.
    for nama, pf in (("kamera 1", pf1), ("kamera 2", pf2)):
        seb = len(panjang_track(pf))
        peta, n = sambung_id(pf)
        ses = len(set(peta.values()))
        print(f"{nama}: {seb} ID -> {ses} ID setelah {n} penyambungan")
        if nama == "kamera 1":
            pf1 = terapkan(pf1, peta)
        else:
            pf2 = terapkan(pf2, peta)

    pj1, pj2 = panjang_track(pf1), panjang_track(pf2)
    print(f"kamera 1: {len(pj1)} ID unik ({sum(1 for v in pj1.values() if v >= MIN_PANJANG)} >= {MIN_PANJANG} frame)")
    print(f"kamera 2: {len(pj2)} ID unik ({sum(1 for v in pj2.values() if v >= MIN_PANJANG)} >= {MIN_PANJANG} frame)")
    out = APP / "results" / "pipeline_final_pantry_2kamera.mp4"
    vw = None
    t0 = time.time()
    ingat = [{}, {}]        # per kamera: tid -> (kotak, sisa_tahan)

    def dengan_tahan(kel, mem):
        """Tambahkan kotak yang baru saja hilang, dari ingatan. Kembalikan
        (daftar_kotak, id_yang_ditahan)."""
        kini = {int(k[4]) for k in kel}
        for tid in list(mem):
            if tid in kini:
                del mem[tid]
        keluar, ditahan = list(kel), []
        for tid, (kotak, sisa) in list(mem.items()):
            if sisa <= 0:
                del mem[tid]
                continue
            mem[tid] = (kotak, sisa - 1)
            keluar.append(kotak)
            ditahan.append(tid)
        for k in kel:
            mem[int(k[4])] = (k, TAHAN)
        return keluar, ditahan

    for i, (a, b) in enumerate(zip(baca_frame(KAMERA[1], JUMLAH),
                                   baca_frame(KAMERA[2], JUMLAH))):
        if i >= len(pf1) or i >= len(pf2):
            break
        k1, t1 = dengan_tahan(pf1[i], ingat[0])
        k2, t2 = dengan_tahan(pf2[i], ingat[1])
        ka = gambar(a, k1, "Pantry - kamera sisi 1", t1)
        kb = gambar(b, k2, "Pantry - kamera sisi 2", t2)
        h = min(ka.shape[0], kb.shape[0])
        frame = np.hstack([ka[:h], kb[:h]])
        if vw is None:
            hh, ww = frame.shape[:2]
            vw = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*"mp4v"),
                                 FPS_OUT, (ww, hh))
        vw.write(frame)
        if (i + 1) % 100 == 0:
            print(f"  render {i + 1}  ({(i + 1) / (time.time() - t0):.1f} fps)", flush=True)
    vw.release()

    if shutil.which("ffmpeg"):
        tmp = out.with_suffix(".tmp.mp4")
        if subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(out),
                           "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                           "-pix_fmt", "yuv420p", "-profile:v", "high",
                           "-movflags", "+faststart", str(tmp)]).returncode == 0:
            tmp.replace(out)
            print("dikonversi ke H.264")
    print("tersimpan:", out)


if __name__ == "__main__":
    main()
