"""Jalankan pipeline Shafa, hasilkan hasil.json LENGKAP untuk aplikasi ini.

Pipeline `backend` milik Shafa dipakai apa adanya — deteksi, tracking, fusi
lintas kamera, dan analitiknya semua miliknya, jadi angkanya sebanding dengan
punya dia. Yang ditambahkan di sini cuma bagian `extra` yang JobResult-nya tidak
kirim tapi aplikasi ini butuhkan: `jejak`, `jejakWaktu`, `grid`, plus `paths`
dan `blobs` yang sebenarnya sudah dia hitung, hanya diletakkan di akar respons.

TIDAK ADA SATU BARIS PUN kode Shafa yang diubah. Modulnya diimpor apa adanya;
satu-satunya penyesuaian adalah `make_tracker` ditukar saat runtime (monkey
patch) karena boxmot di mesin ini versi 22.x sedangkan pipeline-nya dipin ke
13.x — berkasnya tetap utuh di disk.

    python engine/experiments/pakai_pipeline_shafa.py <job.json> [nama-run]
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

import numpy as np

BACKEND = Path("/Users/fitrimaharani/APPLE INSTITUTE/backend-shafa")
KELUARAN = Path.home() / "Documents/crowdflow"

# Cuplikan jejak: 5 = 5 titik/detik pada PROC_FPS 5 (dia memproses 5 fps, jadi
# tiap frame yang diproses ikut dicuplik). Cukup rapat untuk animasi mengalir.
JEJAK_LANGKAH = 1
# Jejak yang hidupnya lebih pendek dari ini dibuang: track sekejap muncul
# sebagai nomor asing yang berkelip lalu lenyap.
JEJAK_MIN_DETIK = 1.0

# Setelan tracker yang DIUKUR di repo ini (reid/hasil_pagar2.csv, 7 kamera):
#     bawaan BoxMOT  proximity 0,5 / appearance 0,25  ->  IDF1 40,13
#     setelan ini    proximity 0,9 / appearance 0,60  ->  IDF1 49,84
#
# proximity_thresh adalah PAGAR: kalau kotak orang dan prediksi posisinya tidak
# cukup tumpang-tindih, penampilan diabaikan sama sekali dan keputusan
# diserahkan ke gerak. Dengan pagar bawaan yang ketat, Re-ID nyaris tidak pernah
# terpakai — dihitung, memakan waktu, lalu dibuang. Itu sebabnya orang yang
# tertutup sebentar langsung dapat ID baru.
#
# Dipasang lewat env TUNING_FITRI=1 supaya perbandingan tetap bisa dilakukan
# dua arah tanpa menyentuh kode Shafa.
BOTSORT_TUNED = dict(
    track_high_thresh=0.25, track_low_thresh=0.25, new_track_thresh=0.25,
    track_buffer=60, match_thresh=0.8,
    proximity_thresh=0.9, appearance_thresh=0.6,
)
TUNING = os.environ.get("TUNING_FITRI") == "1"

# Penyambungan ID temporal dari engine ini, dijalankan DI ATAS hasil tracking
# Shafa. Pipeline dia menyatukan orang ANTAR KAMERA (fusi spasial) tapi tidak
# pernah menyambung orang yang sama DARI WAKTU KE WAKTU: begitu seseorang
# tertutup sebentar, dia dapat nomor baru dan tidak ada tahap yang
# mengembalikannya. Itu sebabnya jumlah orangnya membengkak (81 untuk ruangan
# berisi belasan), dan kenapa memasang setelan tracker yang terukur di sini
# justru memperburuk — setelan itu memang melahirkan lebih banyak fragmen,
# dengan asumsi ada yang merapikan sesudahnya.
# Bawaan MATI sekarang: penyambungan dikerjakan `stitch_tracks` milik Shafa.
# Nyalakan dengan SAMBUNG_ID=1 hanya untuk membandingkan dengan cara lama.
SAMBUNG_FITRI = os.environ.get("SAMBUNG_ID", "0") != "0"


def siapkan_impor():
    """Impor modul Shafa apa adanya, lalu tukar make_tracker di memori saja."""
    sys.path.insert(0, str(BACKEND))
    import boxmot
    from boxmot.trackers.bbox.botsort import BotSort
    from boxmot.reid.core.reid import ReID

    # `track.py` menulis `from boxmot import BotSort` di baris atas modul — sah
    # di boxmot 13.x, tapi 22.x tidak lagi mengekspornya di akar paket. Namanya
    # disuntikkan ke paket BOXMOT (pustaka pihak ketiga), bukan ke kode Shafa,
    # supaya impornya berhasil tanpa satu pun berkasnya disentuh.
    if not hasattr(boxmot, "BotSort"):
        boxmot.BotSort = BotSort

    import pipeline.track as track_shafa

    def make_tracker_22x(cfg):
        # boxmot 22.x menerima objek model (reid_model), bukan path
        # (reid_weights) seperti 13.x.
        dev = getattr(cfg, "REID_DEVICE", cfg.DEVICE)
        ext = ReID(str(cfg.REID_WEIGHTS), device=dev, half=False).model
        setelan = dict(with_reid=getattr(cfg, "WITH_REID", True))
        if TUNING:
            setelan.update(BOTSORT_TUNED)
        return BotSort(reid_model=ext, **setelan)

    track_shafa.make_tracker = make_tracker_22x
    return track_shafa


def sambung_temporal(tracks: dict, per_frame: dict, proc_fps: float):
    """Satukan fragmen milik orang yang sama, memakai `sambung_id` engine ini.

    Kembalikan (tracks, per_frame, jumlah_penyambungan) dengan ID yang sudah
    disatukan.
    """
    import importlib.util
    berkas = Path(__file__).parent / "viz_pipeline_2kamera.py"
    spec = importlib.util.spec_from_file_location("_vp", berkas)
    vp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vp)

    # Ambangnya ditulis dalam FRAME, dan dikalibrasi untuk 20 fps. Pipeline ini
    # berjalan di PROC_FPS (biasanya 5–10), jadi kalau dibiarkan, jendela
    # 240 frame yang seharusnya 12 detik berubah jadi 24 detik atau lebih —
    # menyambung orang yang sudah lama pergi dengan orang yang baru datang.
    vp.SAMBUNG_JEDA = max(1, int(round(12.0 * proc_fps)))
    vp.SAMBUNG_PER_FRAME = 4.0 * (20.0 / max(proc_fps, 1e-6))

    urut = sorted(per_frame)
    daftar = [[(x1, y1, x2, y2, tid)
               for (tid, x1, y1, x2, y2) in per_frame[i]] for i in urut]
    peta, n = vp.sambung_id(daftar)
    if not n:
        return tracks, per_frame, 0

    per_frame_baru = {i: [(peta.get(tid, tid), x1, y1, x2, y2)
                          for (tid, x1, y1, x2, y2) in per_frame[i]]
                      for i in urut}
    tracks_baru: dict = {}
    for tid, obs in tracks.items():
        tracks_baru.setdefault(peta.get(tid, tid), []).extend(obs)
    for k in tracks_baru:
        tracks_baru[k].sort(key=lambda o: o[0])
    return tracks_baru, per_frame_baru, n


def bikin_paths(jejak_waktu: dict, maks: int = 12) -> list:
    """Lintasan untuk layar Path Simulation, dari jejak kamera ini.

    Disaring seperti engine ini menyaringnya: yang cuma bergoyang di tempat
    dibuang. Orang DUDUK bergoyang terus-menerus, dan goyangan itu menumpuk jadi
    jarak tempuh besar tanpa orangnya berpindah — kalau ikut digambar, layarnya
    terbaca seperti coretan, bukan jalur.
    """
    kandidat = []
    for titik in jejak_waktu.values():
        if len(titik) < 12:
            continue
        pts = [(t[1], t[2]) for t in titik]
        pindah = ((pts[-1][0] - pts[0][0]) ** 2 + (pts[-1][1] - pts[0][1]) ** 2) ** 0.5
        tempuh = sum(((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
                     for a, b in zip(pts, pts[1:]))
        if pindah <= 0.05 or tempuh <= 1e-9 or pindah / tempuh < 0.2:
            continue
        kandidat.append((pindah, pts))

    kandidat.sort(key=lambda x: -x[0])
    keluar = []
    for n, (_, pts) in enumerate(kandidat[:maks]):
        langkah = max(1, len(pts) // 24)
        keluar.append({"points": [[round(x, 4), round(y, 4)]
                                  for x, y in pts[::langkah]],
                       "hue": round((n * 0.13) % 1.0, 3)})
    return keluar


def jalankan(job_path: str, nama_run: str | None = None):
    track_shafa = siapkan_impor()
    from config import Config as cfg
    from models import JobRequest
    from pipeline.detect import load_model, detect_video
    from pipeline.track import track_from_dets, tracks_to_floor
    from pipeline.homography import homography_pixel_to_meter
    from pipeline.fuse import fuse_tracks, stitch_tracks
    from pipeline.analytics import compute_analytics
    import cv2

    req = JobRequest(**json.load(open(job_path)))
    venue = req.venue
    run_id = nama_run or f"run-{uuid.uuid4().hex[:12]}"
    # Lintasan absolut dipakai apa adanya — dipanggil dari server, foldernya
    # sudah ditentukan di sana. Nama biasa tetap masuk ke folder keluaran.
    folder = Path(run_id) if run_id.startswith("/") else KELUARAN / run_id
    print(f"[adaptor] run {run_id} -> {folder}")

    model = load_model(cfg)
    cam_floor, per_kamera, cam_feats = [], [], []

    for c in req.cameras:
        t0 = time.time()
        cap = cv2.VideoCapture(c.videoPath)
        W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        cap.release()

        print(f"[adaptor] {c.label}: deteksi…", flush=True)
        # detect_video mengembalikan dict; daftar deteksinya di kunci "dets"
        # (lihat pemakaiannya di pipeline/run.py).
        hasil_deteksi = detect_video(model, c.videoPath, cfg,
                                     start_sec=c.startSec,
                                     duration_sec=c.durationSec)
        dets = hasil_deteksi["dets"]
        print(f"[adaptor] {c.label}: tracking…", flush=True)
        # Tiga nilai sejak commit 5cda6c9: `feats` adalah ciri penampilan tiap
        # track, dipakai fusi lintas kamera. Versi sebelumnya mengembalikan dua.
        tracks, per_frame, feats = track_from_dets(c.videoPath, dets, cfg)
        cam_feats.append(feats)

        # `sambung_temporal` buatanku SENGAJA tidak dipakai lagi di sini: Shafa
        # sekarang punya `stitch_tracks` sendiri, dan menjalankan dua penyambung
        # berurutan berarti menyambung hasil sambungan — sekali salah gabung,
        # dua orang berbeda melebur permanen. SAMBUNG=1 masih bisa dipakai untuk
        # membandingkan dengan cara lama.
        if SAMBUNG_FITRI:
            tracks, per_frame, n_sambung = sambung_temporal(
                tracks, per_frame, getattr(cfg, "PROC_FPS", 5.0))
            print(f"[adaptor] {c.label}: {n_sambung} fragmen disambung "
                  f"-> {len(tracks)} identitas")

        Hm = homography_pixel_to_meter(c.imagePoints, c.planePoints,
                                       W, H, venue.widthM, venue.heightM)
        cam_floor.append(tracks_to_floor(tracks, Hm))
        per_kamera.append(dict(cam=c, W=W, H=H, fps=fps, tracks=tracks,
                               per_frame=per_frame, detik=time.time() - t0))
        print(f"[adaptor] {c.label}: {len(tracks)} track, "
              f"{len(per_frame)} frame ({per_kamera[-1]['detik']:.0f} dtk)")

    print("[adaptor] fusi lintas kamera…", flush=True)
    # Urutan dan argumen mengikuti pipeline/run.py Shafa persis: fusi memakai
    # ciri penampilan, lalu penyambungan ID miliknya.
    global_tracks, cam_to_global = fuse_tracks(cam_floor, cfg, cam_feats=cam_feats)
    sebelum = len(global_tracks)
    global_tracks, remap = stitch_tracks(global_tracks, cfg)
    cam_to_global = {k: remap.get(v, v) for k, v in cam_to_global.items()}
    print(f"[adaptor] stitch: {sebelum} -> {len(global_tracks)} track")

    # Buang fragmen pendek, sama seperti run.py — tanpa ini satu kedipan deteksi
    # ikut terhitung sebagai satu pengunjung.
    _min_dtk = getattr(cfg, "MIN_TRACK_SEC", 0.0)
    _min_ttk = getattr(cfg, "MIN_TRACK_POINTS", 1)

    def _simpan(obs):
        if len(obs) < _min_ttk:
            return False
        ts = [o[0] for o in obs]
        return (max(ts) - min(ts)) >= _min_dtk

    sebelum = len(global_tracks)
    global_tracks = {g: o for g, o in global_tracks.items() if _simpan(o)}
    print(f"[adaptor] saring: {sebelum} -> {len(global_tracks)} "
          f"(min {_min_dtk}s / {_min_ttk} titik)")

    hasil_analitik, heat = compute_analytics(global_tracks, venue, cfg)
    print(f"[adaptor] {len(global_tracks)} ID global")

    # ---- tulis satu hasil.json per kamera, format aplikasi ini ----
    folder.mkdir(parents=True, exist_ok=True)
    proc_fps = getattr(cfg, "PROC_FPS", 5.0)

    for i, k in enumerate(per_kamera):
        sub = folder / f"kamera-{i + 1}"
        sub.mkdir(exist_ok=True)
        W, H = k["W"], k["H"]

        # jejak & jejakWaktu dari per_frame — ini yang tidak pernah keluar dari
        # JobResult, padahal animasi dan dwell-per-zona bergantung padanya.
        # ID dipetakan ke ID GLOBAL supaya satu orang punya satu nomor di semua
        # kamera; itu bagian yang paling berguna dari fusi Shafa.
        # Nomor frame DIURUTKAN ULANG dari 0. `per_frame` memakai nomor frame
        # asli video — dan videonya mulai di detik 9052, jadi nomornya ratusan
        # ribu. Aplikasi ini menghitung waktu sebagai nomor/fps, jadi angka asli
        # itu memberi timeline 611 menit untuk rekaman 113 detik.
        urutan = {idx: n for n, idx in enumerate(sorted(k["per_frame"]))}

        jejak, jejak_waktu = {}, {}
        for idx in sorted(k["per_frame"]):
            n = urutan[idx]
            if n % JEJAK_LANGKAH:
                continue
            for (tid, x1, y1, x2, y2) in k["per_frame"][idx]:
                gid = cam_to_global.get((i, tid), tid)
                x = round((x1 + x2) / 2 / W, 4)
                y = round(y2 / H, 4)
                jejak.setdefault(str(gid), []).append([x, y])
                jejak_waktu.setdefault(str(gid), []).append([n, x, y])

        remah = {t for t, v in jejak_waktu.items()
                 if len(v) < 2
                 or (v[-1][0] - v[0][0]) / proc_fps < JEJAK_MIN_DETIK}
        jejak = {t: v for t, v in jejak.items() if t not in remah}
        jejak_waktu = {t: v for t, v in jejak_waktu.items() if t not in remah}

        gh, gw = heat.shape
        s = hasil_analitik["summary"]
        keluar = {
            # mulai_detik WAJIB bilangan bulat: aplikasi mengurainya sebagai Int,
            # dan satu angka berpecahan membuat SELURUH respons ditolak dengan
            # "data couldn't be read because it isn't in the correct format" —
            # analisis yang sebenarnya sukses tampil sebagai gagal total.
            "sumber": {"video": Path(k["cam"].videoPath).name,
                       "mulai_detik": int(round(float(k["cam"].startSec or 0))),
                       "frame_diproses": len(k["per_frame"]),
                       "fps_sumber": round(float(proc_fps), 3)},
            "summary": {"totalVisitors": s.totalVisitors,
                        "avgDwellSeconds": s.avgDwellSeconds,
                        "peakOccupancy": s.peakOccupancy,
                        "captureRate": s.captureRate},
            "occupancy": [{"minute": o.minute, "count": o.count}
                          for o in hasil_analitik["occupancy"]],
            "occupancySatuan": "menit",
            "blobs": [{"x": b.x, "y": b.y, "intensity": b.intensity,
                       "radius": b.radius} for b in hasil_analitik.get("blobs", [])],
            # paths DITURUNKAN DARI jejak kamera ini, bukan dari `paths` milik
            # analitik Shafa. Punya dia berada di koordinat LANTAI (meter),
            # sedangkan layar Path Simulation menggambar dari koordinat KAMERA
            # lalu memproyeksikannya sendiri lewat homografi — dua ruang berbeda,
            # dan kalau dipaksa, jalurnya tidak muncul sama sekali.
            "paths": bikin_paths(jejak_waktu),
            "zones": [{"rank": n + 1, "code": z.code, "visits": z.visits,
                       "share": z.share, "x": z.rect.x, "y": z.rect.y,
                       "w": z.rect.w, "h": z.rect.h, "shareRelatif": z.share}
                      for n, z in enumerate(hasil_analitik["zones"])],
            "grid": {"w": gw, "h": gh, "total": int(heat.sum()),
                     "sel": [int(v) for v in heat.flatten()]},
            "jejakLangkah": JEJAK_LANGKAH,
            "jejak": jejak,
            "jejakWaktu": jejak_waktu,
            "stops": [{"label": p.label, "x": p.x, "y": p.y,
                       "dwellSeconds": p.dwellSeconds}
                      for p in hasil_analitik["stopPoints"]],
            # Titik-kaki mentah di koordinat lantai, ditambahkan Shafa di
            # commit "fix: fix zona" untuk zona yang digambar sendiri di
            # aplikasi. Adaptor ini memilih kunci satu per satu, jadi tanpa
            # baris ini fiturnya mati diam-diam untuk lari yang lewat sini.
            "observations": hasil_analitik.get("observations", []),
            "diagnostik": {
                "pipeline": "backend (Shafa) — dipakai apa adanya",
                "id_global": len(global_tracks),
                "catatan": ("stops.dwellSeconds adalah TOTAL waktu-orang "
                            "(dijumlahkan lintas orang), bukan lama satu orang "
                            "duduk. captureRate di sini proxy kontinuitas "
                            "deteksi, bukan recall terukur."),
            },
            "video": "beranotasi.mp4",
        }
        # Video kotak deteksi: dirender pakai fungsi Shafa sendiri, jadi
        # tampilannya sama dengan yang dia hasilkan — termasuk NOMOR GLOBAL,
        # sehingga orang yang sama bernomor sama di kedua kamera.
        try:
            from pipeline.render import render_bbox_video
            render_bbox_video(k["cam"].videoPath, k, cam_to_global, i, cfg,
                              str(sub / "beranotasi.mp4"))
            print(f"[adaptor] {sub.name}: video beranotasi dirender")
        except Exception as e:                                  # noqa: BLE001
            keluar["video"] = None
            print(f"[adaptor] {sub.name}: render video gagal ({e})")

        (sub / "hasil.json").write_text(json.dumps(keluar))
        (sub / "kamera.json").write_text(json.dumps({"label": k["cam"].label}))
        print(f"[adaptor] {sub.name}: {len(jejak)} jejak ditulis "
              f"({len(remah)} remah dibuang)")

    print(f"[adaptor] selesai — buka Riwayat, cari {run_id}")
    return run_id


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    jalankan(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
