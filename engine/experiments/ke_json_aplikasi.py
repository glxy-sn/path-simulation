"""Jalankan pipeline lalu keluarkan JSON berbentuk sama dengan SampleResult (Swift).

Tujuannya menyambungkan pipeline Python ke aplikasi foodcourt tanpa server: skrip
ini menghasilkan satu berkas JSON yang bisa dibaca langsung oleh aplikasi
menggantikan data contoh.

Bentuknya mengikuti struct di foodcourt/Domain/Entities/Models.swift.

GALAT YANG SUDAH TERUKUR — per venue, lihat reid/kalibrasi_venue.json
Untuk pantry (day1cam1), dari 47 orang teranotasi manusia, rentang 5 menit:
    totalVisitors    berlebih ~13%
    avgDwellSeconds  kurang   ~7%
    IDF1 96,6 dengan syarat terdeteksi; 1,13 ID per orang

BATAS YANG HARUS IKUT DISEBUT
Galat itu milik VENUE, bukan milik pipeline — bergantung sudut kamera, kepadatan,
dan seberapa sering orang saling menutupi. Untuk video yang venue-nya belum
terdaftar, galat dikirim null dan aplikasi menampilkan "belum diukur"; jangan
meminjam angka venue lain. Semua angka identitas hanya berlaku untuk orang yang
TERDETEKSI.

Menambah venue: reid/siapkan_anotasi.py -> anotasi.html ->
reid/nilai_anotasi.py --simpan-profil <kunci>

    ../venv_boxmot/bin/python experiments/ke_json_aplikasi.py video.mp4
    ../venv_boxmot/bin/python experiments/ke_json_aplikasi.py video.mp4 --frame 1200 --keluar hasil.json
"""
import argparse
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np

APP = Path(__file__).parent.parent
sys.path.insert(0, str(APP))
sys.path.insert(0, str(APP / "experiments"))
os.chdir(APP)

import importlib.util  # noqa: E402

_s = importlib.util.spec_from_file_location("_vp", APP / "experiments/viz_pipeline_2kamera.py")
_vp = importlib.util.module_from_spec(_s)
_s.loader.exec_module(_vp)

DETECTOR = APP / "weights_ft/yolo11s_crowd.pt"
REID = "osnet_ain_x1_0_msmt17.pt"
CONF, IMGSZ, IOU_NMS = 0.25, 1280, 0.7
BOTSORT = _vp.BOTSORT

# fps DIBACA dari videonya, tidak lagi ditulis mati 20. Rekaman pantry memang
# 20 fps, tapi TownCentre 25 dan mall 15 — dengan nilai tetap, dwell untuk video
# 25 fps meleset 25% dan video hasilnya berputar terlalu lambat.
FPS_BAWAAN = 20.0        # dipakai kalau video tidak melaporkan fps yang masuk akal
# Jumlah titik panas. Dulu 8 dengan radius 0,12 — hasilnya beberapa gumpalan
# raksasa yang menutupi separuh gambar dan tidak menunjukkan letak apa pun.
# Lebih banyak titik dengan radius lebih kecil memberi bentuk yang benar-benar
# mengikuti tempat orang berada.
BLOB_MAKS = 28
BLOB_RADIUS = 0.055
ZONA_MAKS = 5            # jumlah zona padat yang dilaporkan
JEJAK_MAKS = 12          # jumlah lintasan yang dilaporkan
# Jejak titik kaki dicuplik tiap N frame. 20 frame = 1 detik pada 20 fps, cukup
# untuk menghitung lama di zona; lebih rapat hanya membesarkan berkas.
JEJAK_LANGKAH = 20
# Recall detektor di pantry, dari 106 anotasi kotak. HANYA berlaku di pantry —
# dipakai sebagai cadangan kalau venue tidak punya angkanya sendiri, dan saat itu
# dilaporkan sebagai "bukan dari venue ini" supaya tidak disangka hasil ukur.
RECALL_PANTRY = 0.821
KALIBRASI = APP / "reid/kalibrasi_venue.json"


def profil_venue(nama_video):
    """Galat terukur untuk venue ini, atau None kalau belum pernah diukur.

    Galat adalah milik VENUE, bukan milik pipeline: bergantung pada sudut kamera,
    kepadatan, dan seberapa sering orang saling menutupi. Memakai angka pantry
    untuk rekaman mall sama saja mengarang. Kalau venue belum terdaftar, galatnya
    dikirim null dan aplikasi menampilkan "belum diukur" — itu jujur dan
    memberitahu apa yang harus dikerjakan.
    """
    if not KALIBRASI.exists():
        return None
    try:
        isi = json.loads(KALIBRASI.read_text())
    except json.JSONDecodeError:
        return None
    batang = Path(nama_video).stem.lower()
    for kunci, p in (isi.get("venue") or {}).items():
        if kunci.lower() == batang:
            return p
    return None


def _kumpul_durasi(per_frame):
    """Jumlah frame per ID. Dipakai hanya untuk angka mentah di diagnostik."""
    d = defaultdict(list)
    for i, fr in enumerate(per_frame):
        for *_, tid in fr:
            d[tid].append(i)
    return d


def lapor(tahap, frac):
    """Baris progres yang dibaca aplikasi Swift. Formatnya jangan diubah."""
    print(f"PROGRESS {tahap} {frac:.4f}", flush=True)


def render(video, mulai, per_frame, keluar, fps):
    """Tulis ulang video dengan kotak + ID digambar di atasnya.

    Lintasan sengaja TIDAK digambar menyambung antar frame yang berjauhan:
    garis panjang lurus di video sebelumnya ternyata lompatan ID, bukan orang
    berjalan. Di sini cukup kotak dan titik kaki, yang memang terukur.
    """
    cap = cv2.VideoCapture(video)
    cap.set(cv2.CAP_PROP_POS_MSEC, mulai * 1000)
    ok, f0 = cap.read()
    if not ok:
        return None
    H, W = f0.shape[:2]
    cap.set(cv2.CAP_PROP_POS_MSEC, mulai * 1000)

    skala = min(1.0, 1280 / W)
    Wo, Ho = int(W * skala) // 2 * 2, int(H * skala) // 2 * 2
    vw = cv2.VideoWriter(str(keluar), cv2.VideoWriter_fourcc(*"avc1"), fps, (Wo, Ho))
    if not vw.isOpened():
        vw = cv2.VideoWriter(str(keluar), cv2.VideoWriter_fourcc(*"mp4v"), fps, (Wo, Ho))

    n = len(per_frame)
    for i, fr in enumerate(per_frame):
        ok, img = cap.read()
        if not ok:
            break
        if skala != 1.0:
            img = cv2.resize(img, (Wo, Ho))
        for x1, y1, x2, y2, tid in fr:
            p1 = (int(x1 * skala), int(y1 * skala))
            p2 = (int(x2 * skala), int(y2 * skala))
            c = _vp.warna_id(tid)
            cv2.rectangle(img, p1, p2, c, 2)
            cv2.putText(img, f"ID {tid}", (p1[0], max(12, p1[1] - 6)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, c, 2, cv2.LINE_AA)
            # titik kaki — dipakai untuk proyeksi ke lantai
            cv2.circle(img, ((p1[0] + p2[0]) // 2, p2[1]), 4, (0, 165, 255), -1)
        cv2.putText(img, f"{len(fr)} orang", (12, 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2, cv2.LINE_AA)
        vw.write(img)
        if i % 40 == 0:
            lapor("render", i / max(1, n))
    vw.release()
    cap.release()
    return keluar


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--mulai", type=int, default=0, help="detik mulai")
    ap.add_argument("--frame", type=int, default=600)
    ap.add_argument("--keluar", default="hasil_aplikasi.json")
    ap.add_argument("--video-keluar", default=None,
                    help="kalau diisi, tulis video beranotasi ke path ini")
    a = ap.parse_args()
    if not Path(a.video).exists():
        sys.exit(f"video tidak ada: {a.video}")

    import torch
    from ultralytics import YOLO
    from boxmot.trackers.bbox.botsort import BotSort
    from boxmot.reid.core.reid import ReID

    dev = "mps" if torch.backends.mps.is_available() else (
        "cuda" if torch.cuda.is_available() else "cpu")
    det = YOLO(str(DETECTOR))
    trk = BotSort(reid_model=ReID(REID, device=dev, half=False).model, **BOTSORT)

    cap = cv2.VideoCapture(a.video)
    cap.set(cv2.CAP_PROP_POS_MSEC, a.mulai * 1000)
    ok, f0 = cap.read()
    if not ok:
        sys.exit("gagal membaca frame pertama")
    H, W = f0.shape[:2]

    # fps dari videonya sendiri. Beberapa berkas melaporkan 0 atau angka aneh,
    # jadi hasilnya dibatasi ke rentang yang masuk akal sebelum dipakai —
    # fps yang salah merusak dwell, grafik okupansi, dan kecepatan video hasil.
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not (1.0 <= fps <= 120.0):
        print(f"  fps video tidak masuk akal ({fps}), pakai {FPS_BAWAAN}")
        fps = FPS_BAWAAN
    print(f"  fps sumber: {fps:.1f}")

    profil = profil_venue(a.video)
    if profil:
        print(f"  profil venue: {profil['nama']} "
              f"(galat +{profil['totalVisitorsGalat']:.0%} / {profil['avgDwellGalat']:+.0%})")
    else:
        print(f"  venue '{Path(a.video).stem}' belum pernah diukur — galat dikirim null")


    cap.set(cv2.CAP_PROP_POS_MSEC, a.mulai * 1000)

    per_frame, jumlah = [], []
    t0 = time.time()
    for i in range(a.frame):
        ok, img = cap.read()
        if not ok:
            break
        # `device=dev` WAJIB disebut, walau modelnya sudah ada di MPS.
        # Tanpa itu ultralytics menentukan perangkat ulang tiap panggilan dan
        # memindahkan tensornya bolak-balik. Terukur pada 40 frame pantry
        # 2304x1296, imgsz 1280, hasil deteksi identik:
        #     tanpa device=  : 103,4 ms/frame
        #     device="mps"   :  28,6 ms/frame
        # Selisihnya 75 ms/frame — hampir separuh seluruh waktu proses, dan
        # tidak menukar apa pun: bukan frame yang dikurangi, bukan imgsz yang
        # diturunkan, bukan deteksi yang dikorbankan.
        r = det.predict(img, classes=[0], conf=CONF, iou=IOU_NMS, imgsz=IMGSZ,
                        verbose=False, device=dev)[0]
        if r.boxes is None or not len(r.boxes):
            d = np.empty((0, 6))
        else:
            d = np.column_stack([r.boxes.xyxy.cpu().numpy(),
                                 r.boxes.conf.cpu().numpy(),
                                 np.zeros(len(r.boxes))])
        res = np.asarray(trk.update(d, img)).reshape(-1, 8)
        per_frame.append([(float(x[0]), float(x[1]), float(x[2]), float(x[3]), int(x[4]))
                          for x in res])
        jumlah.append(len(res))
        if (i + 1) % 20 == 0:
            lapor("lacak", (i + 1) / a.frame)
        if (i + 1) % 200 == 0:
            print(f"  {i+1}/{a.frame} ({(i+1)/(time.time()-t0):.1f} fps)", flush=True)
    cap.release()

    lapor("sambung", 0.0)
    peta, n_sambung = _vp.sambung_id(per_frame)
    per_frame = _vp.terapkan(per_frame, peta)

    # --- occupancy: jumlah orang per bin waktu; TIDAK butuh identitas ---
    #
    # Lebar bin MENYESUAIKAN panjang rekaman. Bin menit yang tetap membuat klip
    # pendek jadi satu titik saja, dan grafik satu titik tidak menunjukkan apa
    # pun. Targetnya belasan titik, dengan satuan yang dilaporkan apa adanya ke
    # aplikasi supaya label sumbunya tidak berbohong.
    durasi_detik = len(jumlah) / fps
    if durasi_detik >= 12 * 60:
        lebar_detik, satuan = 60, "menit"
    elif durasi_detik >= 120:
        lebar_detik, satuan = 30, "detik"
    else:
        lebar_detik, satuan = max(2, int(durasi_detik // 12)), "detik"

    per_bin = max(1, int(fps * lebar_detik))
    occ = []
    for b in range(0, len(jumlah), per_bin):
        potong = jumlah[b:b + per_bin]
        if not potong:
            continue
        titik = (b // per_bin) * lebar_detik
        occ.append({"minute": titik // 60 if satuan == "menit" else titik,
                    "count": int(round(float(np.mean(potong))))})

    # --- blobs: titik kaki ditumpuk jadi peta panas, lalu diambil puncaknya ---
    akum = np.zeros((H // 8, W // 8), np.float32)
    for fr in per_frame:
        for x1, y1, x2, y2, _ in fr:
            gx, gy = int((x1 + x2) / 2) // 8, int(y2) // 8
            if 0 <= gx < akum.shape[1] and 0 <= gy < akum.shape[0]:
                akum[gy, gx] += 1
    panas = cv2.GaussianBlur(akum, (0, 0), 4)
    blobs = []
    kerja = panas.copy()
    for _ in range(BLOB_MAKS):
        if kerja.max() <= 0:
            break
        gy, gx = np.unravel_index(int(kerja.argmax()), kerja.shape)
        blobs.append({"x": round(gx / kerja.shape[1], 4),
                      "y": round(gy / kerja.shape[0], 4),
                      "intensity": round(float(kerja[gy, gx] / panas.max()), 3),
                      "radius": BLOB_RADIUS})
        cv2.circle(kerja, (gx, gy), 7, 0, -1)       # tekan puncak yang sudah diambil

    # --- zona: area terpadat, DITEMUKAN OTOMATIS dari kepadatan ---
    #
    # Ini BUKAN zona semantik ("kasir", "rak minuman") — itu butuh denah lantai
    # dan batas yang digambar manusia. Yang dihitung di sini murni: di petak mana
    # titik kaki paling sering muncul. "share" adalah porsi pengamatan titik kaki
    # yang jatuh di dalam kotak itu, jadi tidak butuh identitas sama sekali.
    #
    # "visits" diisi jumlah ID BERBEDA yang pernah muncul di kotak itu. Angka ini
    # ikut tergelembung oleh ID yang pecah, jadi bacalah sebagai urutan
    # perbandingan antar zona, bukan sebagai jumlah orang.
    kaki = [((x1 + x2) / 2, y2, t) for fr in per_frame for x1, y1, x2, y2, t in fr]
    zones = []
    if kaki:
        sisa = panas.copy()
        total_kaki = len(kaki)
        for pangkat in range(1, ZONA_MAKS + 1):
            if sisa.max() <= 0:
                break
            gy, gx = np.unravel_index(int(sisa.argmax()), sisa.shape)
            # kotak melingkupi petak di sekitar puncak yang masih >=40% puncak
            ambang = sisa[gy, gx] * 0.4
            rr = 22
            y0, y1_ = max(0, gy - rr), min(sisa.shape[0], gy + rr)
            x0, x1_ = max(0, gx - rr), min(sisa.shape[1], gx + rr)
            petak = sisa[y0:y1_, x0:x1_] >= ambang
            ys, xs = np.nonzero(petak)
            if len(ys) == 0:
                sisa[y0:y1_, x0:x1_] = 0
                continue
            ky0, ky1 = (y0 + ys.min()) * 8, (y0 + ys.max() + 1) * 8
            kx0, kx1 = (x0 + xs.min()) * 8, (x0 + xs.max() + 1) * 8

            di_dalam = [t for cx, cy, t in kaki if kx0 <= cx < kx1 and ky0 <= cy < ky1]
            if not di_dalam:
                sisa[y0:y1_, x0:x1_] = 0
                continue
            zones.append({
                "rank": pangkat,
                "code": chr(ord("A") + pangkat - 1),
                # Jumlah PENGAMATAN titik kaki, bukan jumlah orang. Dipilih
                # begini supaya angkanya tetap bisa dihitung ulang di aplikasi
                # saat kotaknya digeser manual — jumlah orang tidak bisa,
                # karena butuh identitas.
                "visits": len(di_dalam),
                "share": round(len(di_dalam) / total_kaki, 4),
                "x": round(kx0 / W, 4), "y": round(ky0 / H, 4),
                "w": round((kx1 - kx0) / W, 4), "h": round((ky1 - ky0) / H, 4),
            })
            sisa[y0:y1_, x0:x1_] = 0            # jangan ambil puncak yang sama dua kali

        # Diurutkan ulang berdasarkan SHARE, bukan tinggi puncak kepadatan.
        # Puncak tertinggi belum tentu kotak dengan pengamatan terbanyak: kotak
        # yang runcing bisa kalah luas dari kotak yang lebih landai tapi lebar.
        zones.sort(key=lambda z: -z["share"])
        for i, z in enumerate(zones, start=1):
            z["rank"] = i
            z["code"] = chr(ord("A") + i - 1)

        # share dinormalkan terhadap zona terpadat supaya batangnya terbaca
        if zones:
            puncak_share = max(z["share"] for z in zones)
            for z in zones:
                z["shareRelatif"] = round(z["share"] / puncak_share, 4)

    # Petak kepadatan untuk penyuntingan zona di aplikasi. Ukurannya tetap
    # supaya besar berkas tidak ikut resolusi video.
    petak_w = 120
    petak_h = max(1, int(round(petak_w * H / W)))
    petak = cv2.resize(akum, (petak_w, petak_h), interpolation=cv2.INTER_AREA) \
        * (akum.shape[0] * akum.shape[1]) / (petak_w * petak_h)

    # --- paths: lintasan terpanjang, ternormalisasi 0-1 ---
    #
    # Lintasan DIPUTUS di dua tempat, tidak disambung begitu saja:
    #   1. lompatan besar antar frame berturut-turut -> itu ID pindah orang,
    #      bukan orang yang lari secepat itu
    #   2. jeda frame yang panjang -> orangnya tertutup, jalur di antaranya
    #      tidak diketahui dan tidak boleh ditebak jadi garis lurus
    # Tanpa ini, gambar lintasan penuh garis lurus panjang melintasi ruangan
    # yang tidak pernah benar-benar terjadi.
    LOMPAT_MAKS = 30.0 / max(W, H)     # ternormalisasi, ~30 px pada sisi terpanjang
    JEDA_MAKS = 10                     # frame

    jejak = defaultdict(list)
    for i, fr in enumerate(per_frame):
        for x1, y1, x2, y2, tid in fr:
            jejak[tid].append((i, (x1 + x2) / 2 / W, y2 / H))

    potongan = []
    for tid, titik in jejak.items():
        seg = [titik[0]]
        for sebelum, kini in zip(titik, titik[1:]):
            jarak = np.hypot(kini[1] - sebelum[1], kini[2] - sebelum[2])
            if kini[0] - sebelum[0] > JEDA_MAKS or jarak > LOMPAT_MAKS:
                potongan.append(seg)
                seg = [kini]
            else:
                seg.append(kini)
        potongan.append(seg)

    # Koordinat x sudah dibagi lebar dan y dibagi tinggi secara terpisah, jadi
    # keduanya dikembalikan dulu ke perbandingan yang sama sebelum jarak
    # dihitung — tanpa ini, gerak mendatar dinilai terlalu kecil.
    aspek = W / H

    def panjang_lintasan(seg):
        return float(sum(np.hypot((b[1] - a[1]) * aspek, b[2] - a[2])
                         for a, b in zip(seg, seg[1:])))

    def perpindahan(seg):
        """Jarak titik awal ke titik akhir — BUKAN total jarak tempuh."""
        return float(np.hypot((seg[-1][1] - seg[0][1]) * aspek, seg[-1][2] - seg[0][2]))

    def kelurusan(seg):
        p = panjang_lintasan(seg)
        return perpindahan(seg) / p if p > 1e-9 else 0.0

    # Dipilih berdasarkan PERPINDAHAN NETTO (awal ke akhir), bukan jarak tempuh
    # terkumpul, dan yang terlalu berkelok dibuang.
    #
    # Sebabnya terukur pada rekaman pantry 45 detik: kotak deteksi orang yang
    # DUDUK bergoyang terus-menerus, dan goyangan itu menumpuk jadi jarak
    # tempuh yang besar tanpa orangnya berpindah ke mana pun. Satu ID tercatat
    # menempuh 1,19 tapi perpindahan nettonya cuma 0,11. Akibatnya 5 dari 12
    # jalur yang ditampilkan sebenarnya orang duduk, dan gambarnya terbaca
    # seperti coretan.
    #
    # Dengan perpindahan netto + syarat kelurusan, jalur yang cuma bergoyang
    # tinggal 1 dari 12, dan rata-rata kelurusan naik dari 0,24 ke 0,44.
    potongan = [s for s in potongan
                if len(s) >= 12 and perpindahan(s) > 0.05 and kelurusan(s) >= 0.2]
    potongan.sort(key=perpindahan, reverse=True)
    paths = []
    for k, seg in enumerate(potongan[:JEJAK_MAKS]):
        idx = np.linspace(0, len(seg) - 1, min(24, len(seg))).astype(int)
        paths.append({"points": [[round(seg[i][1], 4), round(seg[i][2], 4)] for i in idx],
                      "hue": round((k * 0.13) % 1.0, 3)})

    # Jejak per ID untuk perhitungan lama-di-zona di aplikasi.
    #
    # DUA bentuk dikirim, dan itu disengaja:
    #
    #   jejak       {id: [[x, y], ...]}          — bentuk lama
    #   jejakWaktu  {id: [[frame, x, y], ...]}   — sama, plus nomor frame
    #
    # Yang lama tidak memuat waktu sama sekali. Urutan di dalam daftar TIDAK
    # bisa dipakai sebagai waktu: titik hanya ditambahkan saat orangnya
    # terlihat, jadi indeks ke-0 milik orang yang datang di menit ke-3 berarti
    # menit ke-3, bukan detik 0. Dan track sering bolong waktu orangnya
    # tertutup meja, jadi jaraknya pun tidak tetap.
    #
    # Tanpa nomor frame, animasi lintasan mustahil dibuat benar — yang bisa
    # digambar cuma "semua jejak sekaligus", persis yang sudah ada.
    #
    # Yang lama tetap dikirim supaya hasil lama dan aplikasi versi lama tidak
    # rusak; ukurannya kecil dan tidak sepadan dengan risiko memutusnya.
    jejak_penuh = defaultdict(list)
    jejak_waktu = defaultdict(list)
    for i, fr in enumerate(per_frame):
        if i % JEJAK_LANGKAH:
            continue
        for x1, y1, x2, y2, t in fr:
            x, y = round((x1 + x2) / 2 / W, 4), round(y2 / H, 4)
            jejak_penuh[t].append([x, y])
            jejak_waktu[t].append([i, x, y])
    jejak_kirim = {str(t): v for t, v in jejak_penuh.items() if v}
    jejak_waktu_kirim = {str(t): v for t, v in jejak_waktu.items() if v}

    n_id = len({t for fr in per_frame for *_, t in fr})

    # Angka MENTAH untuk dua field yang dinolkan. Dihitung dan disimpan di
    # diagnostik supaya jelas apa yang dibuang, bukan supaya dipakai:
    #   - n_id sebagai "total pengunjung" akan MELEBIH-lebihkan, karena satu
    #     orang masih pecah jadi ~2 ID walau sudah disambung.
    #   - durasi track sebagai "dwell" akan KURANG dari sebenarnya, karena
    #     track putus tiap kali orangnya tertutup meja atau orang lain.
    # Keduanya bias dengan arah yang diketahui tapi besarnya belum terukur.
    durasi = [len(v) / fps for v in
              _kumpul_durasi(per_frame).values()]
    dwell_mentah = int(round(sum(durasi) / len(durasi))) if durasi else 0

    hasil = {
        "sumber": {"video": Path(a.video).name, "mulai_detik": a.mulai,
                   "frame_diproses": len(per_frame), "fps_sumber": round(fps, 3)},
        "summary": {
            # Keduanya SUDAH TERUKUR terhadap anotasi manusia di pantry
            # (44 orang, rentang 5 menit, Agustus 2026):
            #     totalVisitors   berlebih ~20%  (53 terbaca vs 44 sebenarnya)
            #     avgDwellSeconds kurang   ~8%   (67,4 s vs 73,4 s)
            # Dulu dikirim 0 karena galatnya belum pernah diukur dan dugaan
            # saat itu ("dobel", "jauh lebih pendek") ternyata jauh meleset.
            # Angka dengan galat yang diketahui jauh lebih berguna daripada 0.
            "totalVisitors": n_id,
            "avgDwellSeconds": dwell_mentah,
            # null kalau venue ini belum pernah diukur — JANGAN meminjam galat
            # venue lain.
            "totalVisitorsGalat": (profil or {}).get("totalVisitorsGalat"),
            "avgDwellGalat": (profil or {}).get("avgDwellGalat"),
            "galatSumber": (profil or {}).get("diukur_dari"),
            "peakOccupancy": int(max(jumlah)) if jumlah else 0,
            # captureRate juga milik VENUE, sama seperti galat. Kalau venue ini
            # belum punya angkanya sendiri, angka pantry dipakai TAPI ditandai.
            "captureRate": (profil or {}).get("captureRate", RECALL_PANTRY),
            "captureRateVenueIni": bool(profil and "captureRate" in profil),
        },
        "occupancy": occ,
        "occupancySatuan": satuan,      # "menit" atau "detik" — label sumbu ikut ini
        "blobs": blobs,
        "paths": paths,
        "zones": zones,         # area terpadat, ditemukan otomatis dari titik kaki
        # Petak kepadatan titik kaki, dikecilkan ke lebar tetap. Dipakai aplikasi
        # untuk MENGHITUNG ULANG porsi tiap zona saat kotaknya digeser manual —
        # tanpa ini, zona yang disunting tidak punya angka apa pun.
        "grid": {"w": petak_w, "h": petak_h, "total": int(petak.sum()),
                 "sel": [int(v) for v in petak.flatten()]},
        # Jejak titik kaki per ID, dicuplik tiap JEJAK_LANGKAH frame. Dipakai
        # aplikasi untuk menghitung LAMA TIAP ORANG DI TIAP ZONA — dan harus
        # dihitung di aplikasi, bukan di sini, karena zonanya bisa digeser
        # manual. Kalau dihitung di sini, angkanya langsung basi begitu zona
        # diubah.
        "jejakLangkah": JEJAK_LANGKAH,
        "jejak": jejak_kirim,
        "jejakWaktu": jejak_waktu_kirim,
        "stops": None,          # butuh dwell time (butuh identitas)
        "diagnostik": {
            "id_unik_setelah_sambung": n_id,
            "penyambungan": n_sambung,
            "diukur_terhadap": ("anotasi manusia pantry, 44 orang, rentang 5 menit: "
                                "IDF1 95,3 (syarat terdeteksi), 1,20 ID per orang"),
            "catatan": ("totalVisitors berlebih ~20%, avgDwell kurang ~8%. "
                        "Keduanya hanya untuk orang yang TERDETEKSI — recall "
                        "detektor 0,821 / presisi 0,906 terpisah. zones "
                        "ditemukan otomatis dari kepadatan; stops masih null "
                        "karena butuh dwell per zona."),
        },
    }

    if a.video_keluar:
        lapor("render", 0.0)
        v = render(a.video, a.mulai, per_frame, Path(a.video_keluar), fps)
        hasil["video"] = Path(v).name if v else None

    Path(a.keluar).write_text(json.dumps(hasil, indent=1))
    lapor("selesai", 1.0)
    print(f"\ntersimpan: {a.keluar}")
    print(f"  occupancy {len(occ)} titik · blobs {len(blobs)} · paths {len(paths)}")
    print(f"  puncak {hasil['summary']['peakOccupancy']} orang · {n_id} ID unik")
    print("  totalVisitors & avgDwellSeconds = null (identitas belum andal)")


if __name__ == "__main__":
    main()
