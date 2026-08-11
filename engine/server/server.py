#!/usr/bin/env python3
"""
Server engine CrowdFlow — jembatan HTTP antara aplikasi SwiftUI dan pipeline
Re-ID (ke_json_aplikasi.py).

Kontraknya ditentukan lebih dulu di sisi Swift (EngineAPI.swift):

    GET  /health                 -> {"status","device"}
    POST /jobs                   -> {"jobId"}
    GET  /jobs/<id>/progress     -> {"jobId","status","stage","fraction","error"}
    GET  /jobs/<id>/result       -> JobResultDTO
    GET  /files/<id>/<nama>      -> berkas hasil (video beranotasi)

Kenapa HTTP dan bukan subprocess langsung dari Swift: kontrak ini tidak terikat
ke macOS. Kalau antarmukanya nanti pindah ke web, server yang sama dipakai
tanpa diubah — yang berganti cuma pemanggilnya.

Pustaka standar saja (http.server, threading, subprocess). Tidak ada Flask atau
FastAPI supaya tidak menambah dependensi ke venv yang sudah berisi torch,
ultralytics, dan boxmot.

Jalankan:
    venv_boxmot/bin/python crowdflow_app/server/server.py
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP = Path(__file__).resolve().parent.parent          # crowdflow_app/
AKAR = APP.parent                                      # challenge2/
SKRIP = APP / "experiments/ke_json_aplikasi.py"
PYTHON = os.environ.get("CROWDFLOW_PYTHON", str(AKAR / "venv_boxmot/bin/python"))

# Mesin analisisnya bisa ditukar ke pipeline `backend` milik Shafa. Yang berubah
# hanya SIAPA yang menghitung — keluarannya tetap format ini, jadi Riwayat,
# denah, animasi, dan zona di aplikasi tetap hidup.
#
# Bedanya bukan sekadar model: pipeline itu menyatukan identitas LINTAS KAMERA
# (satu orang satu nomor di semua sudut), sesuatu yang pipeline di sini tidak
# pernah berhasil lakukan. Sebaliknya dia tidak punya penyambungan ID temporal,
# jadi jumlah orangnya cenderung berlebih. Dua-duanya disimpan supaya bisa
# dibandingkan kapan saja, bukan dipilih sekali lalu yang lain dibuang.
ADAPTOR_SHAFA = APP / "experiments/pakai_pipeline_shafa.py"
PAKAI_SHAFA = os.environ.get("PAKAI_PIPELINE_SHAFA", "1") != "0"

# Profil kalibrasi tetap. Kalau diisi, titik dari profil ini MENANG atas titik
# yang tersimpan di sesi aplikasi — dipakai supaya semua analisis memakai
# kalibrasi yang sama, bukan kalibrasi lama yang kebetulan masih tersimpan.
PROFIL_KALIBRASI = os.environ.get("CROWDFLOW_PROFIL_KALIBRASI", "")

# Hasil ditulis ke tempat yang sama dengan versi subprocess, supaya layar
# Riwayat di aplikasi tetap menemukan lari lama maupun baru.
KELUARAN = Path.home() / "Documents/crowdflow"

HOST = os.environ.get("CROWDFLOW_HOST", "127.0.0.1")
PORT = int(os.environ.get("CROWDFLOW_PORT", "8765"))

# Warna zona, senada dengan palet di sisi Swift.
PALET = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]


# ---------------------------------------------------------------- perangkat

def perangkat() -> str:
    """Nama perangkat hitung, untuk /health.

    Ditanyakan ke PYTHON (venv pipeline), bukan ke penafsir yang menjalankan
    server ini. Keduanya memang berbeda: server sengaja pustaka standar saja
    supaya bisa dijalankan dengan `python3` polos — jadi `import torch` di
    sini SELALU gagal, dan /health selalu melapor "tidak diketahui" padahal
    pipeline-nya berjalan di MPS dengan baik.
    """
    kode = ("import torch;"
            "print('mps' if torch.backends.mps.is_available()"
            " else 'cuda' if torch.cuda.is_available() else 'cpu')")
    try:
        keluar = subprocess.run([PYTHON, "-c", kode], capture_output=True,
                                text=True, timeout=60)
        baris = keluar.stdout.strip().splitlines()
        nama = baris[-1].strip() if baris else ""
        return nama if nama in ("mps", "cuda", "cpu") else "tidak diketahui (venv)"
    except Exception as e:                                   # noqa: BLE001
        return f"tidak diketahui ({type(e).__name__})"


def info_video(path: str) -> tuple[float, int, int]:
    """fps, lebar, dan tinggi berkasnya sendiri.

    fps dipakai untuk mengubah durasi (detik) yang diminta aplikasi menjadi
    jumlah frame yang dimengerti pipeline. Nilai di luar akal (0, atau ribuan)
    muncul di sebagian rekaman CCTV; dalam kasus itu pipeline juga jatuh ke
    20 fps, jadi dua-duanya sepakat.

    Ukuran frame dikirim ke aplikasi karena koordinat di hasil.json sudah
    dibagi lebar dan tinggi secara TERPISAH. Tanpa tahu rasio aslinya,
    aplikasi tidak bisa menggambar jalur dengan bentuk yang benar — jalur
    melebar atau memipih mengikuti bentuk kotak gambarnya, bukan mengikuti
    gerak orangnya."""
    try:
        import cv2
        cap = cv2.VideoCapture(path)
        f = cap.get(cv2.CAP_PROP_FPS)
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        cap.release()
        return (f if 1.0 <= f <= 120.0 else 20.0), w, h
    except Exception:                                        # noqa: BLE001
        return 20.0, 0, 0


def simpan_frame(path: str, detik: int, tujuan: Path) -> Path | None:
    """Satu frame dari video, dipakai aplikasi sebagai LATAR gambar jalur.

    Koordinat di hasil.json adalah koordinat gambar kamera (x/lebar, y/tinggi),
    jadi frame ini menempel persis tanpa proyeksi apa pun. Tanpa latar, jalur
    tergambar melayang di atas kotak kosong dan tidak ada yang bisa tahu mana
    meja, mana konter — orang tidak mengenali tempatnya sendiri.
    """
    try:
        import cv2
        cap = cv2.VideoCapture(path)
        cap.set(cv2.CAP_PROP_POS_MSEC, detik * 1000)
        ok, frame = cap.read()
        cap.release()
        if not ok:
            return None
        cv2.imwrite(str(tujuan), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
        return tujuan
    except Exception as e:                                   # noqa: BLE001
        print(f"  gagal menyimpan frame latar: {e}", flush=True)
        return None


# ------------------------------------------------------------------- job

class Job:
    """Satu permintaan analisis. Dikerjakan di thread sendiri; handler HTTP
    hanya membaca ringkasannya, jadi /progress tidak pernah ikut menunggu."""

    def __init__(self, jid: str, req: dict):
        self.id = jid
        self.req = req
        self.status = "queued"        # queued | running | done | error
        self.stage = "menyiapkan"
        self.fraction = 0.0
        self.error: str | None = None
        self.result: dict | None = None
        self.dir = KELUARAN / f"run-{jid}"
        self.proc: subprocess.Popen | None = None
        self.kunci = threading.Lock()

    # -- laporan untuk /progress
    def ringkas(self) -> dict:
        with self.kunci:
            return {"jobId": self.id, "status": self.status, "stage": self.stage,
                    "fraction": round(self.fraction, 4), "error": self.error}

    def _maju(self, stage: str, frac: float):
        with self.kunci:
            self.stage = stage
            # Pecahan tidak boleh mundur: tahap render melapor dari 0 lagi, dan
            # bar yang menyusut terbaca seperti kegagalan.
            self.fraction = max(self.fraction, min(1.0, frac))

    def batal(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()

    # -- eksekusi
    def jalankan(self):
        try:
            self._jalankan()
        except Exception as e:                               # noqa: BLE001
            with self.kunci:
                self.status = "error"
                self.error = f"{type(e).__name__}: {e}"

    def _jalankan(self):
        cams = self.req.get("cameras") or []
        if not cams:
            raise ValueError("Permintaan tidak memuat kamera.")

        self.dir.mkdir(parents=True, exist_ok=True)
        with self.kunci:
            self.status = "running"
            self.stage = "memuat model"

        # Tiap kamera dianalisis SENDIRI-SENDIRI dan berurutan.
        #
        # Bukan digabung: menggabungkan identitas antar kamera butuh Re-ID
        # lintas kamera, dan itu terukur ~20% akurasinya di data ini — tidak
        # layak dipakai. Yang bisa dipertanggungjawabkan adalah menampilkan
        # tiap sudut apa adanya, lalu menjumlahkan HANYA yang boleh
        # dijumlahkan (lihat gabungkan() di bawah).
        if PAKAI_SHAFA:
            hasil_kamera = self._pipeline_shafa(cams)
        else:
            hasil_kamera = []
            for i, cam in enumerate(cams):
                hasil_kamera.append(self._satu_kamera(i, len(cams), cam))

        # SALINAN, bukan rujukan. `utama = hasil_kamera[0]` membuat objek itu
        # memuat dirinya sendiri lewat "cameras", dan json.dumps menolaknya
        # dengan "Circular reference detected" — job selesai tapi hasilnya
        # tidak bisa diambil sama sekali.
        utama = dict(hasil_kamera[0])
        utama["cameras"] = hasil_kamera
        utama["gabungan"] = gabungkan(hasil_kamera)

        # Daftar video tingkat-atas harus memuat SEMUA sudut. Karena `utama`
        # disalin dari kamera pertama, tanpa ini yang terdaftar cuma kamera 1 —
        # video kamera 2 tetap dirender (39 MB di disk) tapi tidak pernah bisa
        # dibuka dari layar Hasil. Label diambil dari tiap kamera sendiri;
        # sebelumnya semuanya memakai label kamera pertama, jadi dua sudut
        # tampil dengan nama yang sama.
        satukan_video(hasil_kamera, utama)
        self.result = utama
        with self.kunci:
            self.status = "done"
            self.stage = "selesai"
            self.fraction = 1.0

    def _pipeline_shafa(self, cams: list[dict]) -> list[dict]:
        """Analisis SEMUA kamera sekaligus lewat pipeline Shafa.

        Sekaligus, bukan satu per satu seperti `_satu_kamera`: fusi lintas
        kameranya membandingkan posisi orang di lantai pada waktu yang sama,
        jadi dia butuh seluruh kamera hadir bersamaan. Memanggilnya per kamera
        akan menghasilkan fusi yang tidak pernah punya pasangan.
        """
        n = len(cams)
        self._maju("menyiapkan pipeline", 0.02)

        # Permintaan dari aplikasi diteruskan apa adanya — titik kalibrasi yang
        # baru saja diklik pengguna ikut, jadi hasilnya memakai kalibrasi itu,
        # bukan berkas job yang ditulis tangan.
        isi_job = {
            "venue": self.req.get("venue") or {},
            "mode": self.req.get("mode", "lengkap"),
            "options": self.req.get("options") or {},
            "cameras": cams,
        }
        # ...KECUALI kalau ada profil kalibrasi tetap yang dipilih. Titik yang
        # tersimpan di sesi aplikasi pernah menang diam-diam atas profil yang
        # sengaja diimpor, dan hasilnya diproses dengan kalibrasi yang salah
        # tanpa satu pun tanda di layar.
        if PROFIL_KALIBRASI:
            pakai_profil(isi_job, PROFIL_KALIBRASI)

        job = self.dir / "job.json"
        job.write_text(json.dumps(isi_job))
        cams = isi_job["cameras"]

        perintah = [PYTHON, str(ADAPTOR_SHAFA), str(job), str(self.dir)]
        self.proc = subprocess.Popen(
            perintah, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, cwd=str(AKAR))

        ekor: list[str] = []
        for baris in self.proc.stdout:                        # type: ignore[union-attr]
            baris = baris.rstrip()
            print(f"[{self.id[:8]}/shafa] {baris}", flush=True)
            ekor.append(baris)
            del ekor[:-40]
            # Progres ditaksir dari tahap yang dicetak adaptor. Kasar, tapi
            # lebih baik daripada bar diam belasan menit tanpa keterangan.
            for kunci, (tahap, frac) in {
                "deteksi": ("mendeteksi orang", 0.25),
                "tracking": ("melacak", 0.55),
                "fusi": ("menyatukan antar kamera", 0.75),
                "video beranotasi": ("merender video", 0.9),
            }.items():
                if kunci in baris:
                    self._maju(tahap, frac)
                    break

        if self.proc.wait() != 0:
            raise RuntimeError("pipeline Shafa gagal\n" + "\n".join(ekor[-12:]))

        hasil_kamera = []
        for i, cam in enumerate(cams):
            sub = self.dir / f"kamera-{i + 1}"
            berkas = sub / "hasil.json"
            if not berkas.exists():
                raise RuntimeError(f"pipeline Shafa tidak menulis {berkas}")
            label = cam.get("label") or f"Kamera {i + 1}"
            _, lebar, tinggi = info_video(cam.get("videoPath") or "")
            latar = simpan_frame(cam.get("videoPath") or "",
                                 int(round(float(cam.get("startSec") or 0))),
                                 sub / "latar.jpg")
            mentah = json.loads(berkas.read_text())
            hasil = petakan(self.id, self.req, mentah, sub, n, lebar, tinggi, latar)
            hasil["label"] = label
            hasil_kamera.append(hasil)

        # Layar Hasil menggabungkan dua kamera dan menggambar di atas denah
        # HANYA kalau tiap kamera punya homografi + ukuran frame + ukuran
        # ruangan, dan ketiganya dibaca dari kalibrasi.json di folder kamera.
        # Tanpa berkas itu tampilannya jatuh ke satu kamera di atas frame CCTV,
        # tanpa satu pun pesan yang menjelaskan kenapa.
        if PROFIL_KALIBRASI:
            salin_profil(Path(PROFIL_KALIBRASI), self.dir, len(cams))
        return hasil_kamera

    def _satu_kamera(self, i: int, n: int, cam: dict) -> dict:
        video = cam.get("videoPath") or ""
        label = cam.get("label") or f"Kamera {i + 1}"
        if not Path(video).exists():
            raise FileNotFoundError(f"video tidak ditemukan ({label}): {video}")

        mulai = int(round(float(cam.get("startSec") or 0)))
        durasi = cam.get("durationSec")
        fps, lebar, tinggi = info_video(video)
        frame = max(1, int(round(float(durasi) * fps)) if durasi else 600)

        # Satu subfolder per kamera. Tanpa ini, kamera kedua menimpa hasil
        # kamera pertama dan yang tersisa cuma satu.
        sub = self.dir if n == 1 else self.dir / f"kamera-{i + 1}"
        sub.mkdir(parents=True, exist_ok=True)
        json_keluar = sub / "hasil.json"
        video_keluar = sub / "beranotasi.mp4"
        latar = simpan_frame(video, mulai, sub / "latar.jpg")

        perintah = [PYTHON, str(SKRIP), video,
                    "--mulai", str(mulai),
                    "--frame", str(frame),
                    "--keluar", str(json_keluar)]
        if (self.req.get("options") or {}).get("renderVideos", True):
            perintah += ["--video-keluar", str(video_keluar)]

        # stderr digabung ke stdout: kalau pipeline mati, pesan Python-nya ikut
        # terbaca di sini dan bisa dikirim ke aplikasi apa adanya.
        self.proc = subprocess.Popen(
            perintah, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, cwd=str(AKAR))

        pola = re.compile(r"^PROGRESS (\S+) ([0-9.]+)")
        ekor: list[str] = []
        for baris in self.proc.stdout:                        # type: ignore[union-attr]
            baris = baris.rstrip()
            m = pola.match(baris)
            if m:
                tahap, f = bobot(m.group(1), float(m.group(2)))
                # Progres dibagi rata antar kamera, supaya bar tidak penuh di
                # kamera pertama lalu diam lama tanpa penjelasan.
                self._maju(f"{label}: {tahap}" if n > 1 else tahap, (i + f) / n)
            else:
                print(f"[{self.id[:8]}/{label}] {baris}", flush=True)
                ekor.append(baris)
                del ekor[:-40]

        kode = self.proc.wait()
        if kode != 0:
            raise RuntimeError(f"pipeline {label} keluar dengan kode {kode}\n"
                               + "\n".join(ekor[-12:]))
        if not json_keluar.exists():
            raise RuntimeError(f"pipeline {label} selesai tapi hasil.json tidak ditulis")

        # Nama sudut yang diketik pengguna ("Kamera 2 (ruang makan)") tidak
        # tersimpan di hasil.json, jadi ditulis terpisah — tanpa ini, membuka
        # lari lama mengembalikan nama seadanya dan pengguna kehilangan
        # keterangan yang justru dia tulis sendiri.
        (sub / "kamera.json").write_text(json.dumps({"label": label}))

        mentah = json.loads(json_keluar.read_text())
        hasil = petakan(self.id, self.req, mentah, sub, n, lebar, tinggi, latar)
        hasil["label"] = label
        return hasil


def gabungkan(kamera: list[dict]) -> dict:
    """Angka yang BOLEH dijumlahkan antar kamera, dan yang tidak.

    Dua kamera di ruangan yang sama tapi menyorot bagian yang berbeda:

      puncak okupansi  BOLEH — tidak ada orang yang berada di dua tempat
                       sekaligus. Tapi dijumlahkan PER SATUAN WAKTU dulu, baru
                       diambil puncaknya: puncak masing-masing kamera belum
                       tentu terjadi pada saat yang sama, jadi menjumlahkan
                       kedua puncak akan melebih-lebihkan.

      total pengunjung TIDAK — orang yang mengambil makanan di sudut satu lalu
                       duduk di sudut lain akan terhitung dua kali. Menyatukan
                       keduanya butuh Re-ID lintas kamera, yang belum ada.

    Angka yang tidak boleh dijumlahkan sengaja tidak dikirim sama sekali,
    bukan dikirim dengan peringatan — angka yang tersedia akan dipakai orang.
    """
    if len(kamera) < 2:
        return {}
    deret: dict[int, int] = {}
    for k in kamera:
        for titik in k.get("occupancy") or []:
            m = int(titik.get("minute", 0))
            deret[m] = deret.get(m, 0) + int(titik.get("count", 0))
    if not deret:
        return {}
    return {
        "peakOccupancy": max(deret.values()),
        "occupancy": [{"minute": m, "count": deret[m]} for m in sorted(deret)],
        "satuan": (kamera[0].get("extra") or {}).get("occupancySatuan") or "menit",
        "catatan": (
            f"Puncak okupansi {len(kamera)} kamera dijumlahkan per satuan waktu — "
            "sah karena sudutnya tidak bersinggungan dan waktunya sinkron. "
            "Total pengunjung TIDAK dijumlahkan: orang yang pindah antar sudut "
            "akan terhitung dua kali, dan menyatukannya butuh Re-ID lintas "
            "kamera yang belum ada."),
    }


def bobot(tahap: str, frac: float) -> tuple[str, float]:
    """Pecahan per tahap -> pecahan keseluruhan.

    Angkanya diukur dari lari sungguhan, bukan dibagi rata: pelacakan memakan
    sekitar tiga perempat waktu, penyambungan hampir tidak terasa, sisanya
    render. Bobot rata membuat bar berhenti lama di satu tempat lalu melompat.
    """
    if tahap == "lacak":
        return "Deteksi + tracking (YOLO11s + BoT-SORT + OSNet)", 0.75 * frac
    if tahap == "sambung":
        return "Penyambungan ID", 0.76
    if tahap == "render":
        return "Render video beranotasi", 0.80 + 0.19 * frac
    if tahap == "selesai":
        return "selesai", 1.0
    return tahap, frac


# --------------------------------------------------------------- pemetaan

def uri_berkas(p: Path) -> str:
    """file:// URI yang lolos URL(string:) di Swift.

    Lintasan apa adanya tidak bisa dipakai: "/Users/.../APPLE INSTITUTE/..."
    mengandung spasi, dan URL(string:) mengembalikan nil untuk itu — video
    hasilnya diam-diam tidak muncul."""
    return "file://" + urllib.parse.quote(str(p))


def petakan(jid: str, req: dict, mentah: dict, dirjob: Path, n_cam: int,
            lebar: int = 0, tinggi: int = 0, latar: Path | None = None) -> dict:
    """hasil.json pipeline -> JobResultDTO yang ditunggu aplikasi.

    Bidang tambahan (grid, jejak, blobs, paths, galat) ikut dikirim di luar
    kontrak inti. Kontrak aslinya hanya memuat ringkasan dan zona, padahal
    aplikasi memerlukan grid dan jejak untuk MENGHITUNG ULANG angka zona saat
    kotaknya digeser manual, dan memerlukan galat untuk menuliskan dari mana
    tiap angka berasal. Kalau hanya kontrak inti yang dikirim, kemampuan itu
    hilang tanpa jejak. Bidang tambahan bersifat opsional di sisi Swift, jadi
    pembaca yang tidak memerlukannya tetap bisa membaca respons ini.
    """
    s = mentah.get("summary") or {}
    venue = req.get("venue") or {}

    zones = []
    for i, z in enumerate(mentah.get("zones") or []):
        r = z.get("rect") or z
        zones.append({
            "code": z.get("code") or chr(ord("A") + i),
            "visits": int(z.get("visits") or 0),
            "share": float(z.get("share") or 0.0),
            "rect": {"x": float(r.get("x", 0)), "y": float(r.get("y", 0)),
                     "w": float(r.get("w", r.get("width", 0))),
                     "h": float(r.get("h", r.get("height", 0)))},
            "colorHex": PALET[i % len(PALET)],
        })

    video = dirjob / (mentah.get("video") or "")
    ada_video = bool(mentah.get("video")) and video.exists()

    catatan = []
    if n_cam > 1:
        catatan.append(
            f"{n_cam} kamera dianalisis terpisah. Identitas TIDAK disatukan "
            "antar kamera, jadi orang yang pindah sudut terhitung sebagai dua "
            "orang berbeda.")
    if (req.get("mode") or "") == "lengkap":
        catatan.append(
            "Mode Lengkap: titik kalibrasi diterima tapi belum dipakai "
            "pipeline, jadi hasilnya sama dengan Mode Cepat.")

    return {
        "jobId": jid,
        "venue": venue,
        "summary": {
            "totalVisitors": int(s.get("totalVisitors") or 0),
            "avgDwellSeconds": int(s.get("avgDwellSeconds") or 0),
            "peakOccupancy": int(s.get("peakOccupancy") or 0),
            "captureRate": float(s.get("captureRate") or 0.0),
        },
        "zones": zones,
        # Pipeline belum menghasilkan titik henti bernama — butuh lama-di-zona,
        # dan itu dihitung di aplikasi setelah zonanya disunting.
        "stopPoints": [],
        "occupancy": [{"minute": int(o.get("minute", i)), "count": int(o.get("count", 0))}
                      for i, o in enumerate(mentah.get("occupancy") or [])],
        "artifacts": {
            "heatmapImage": None,          # heatmap digambar di aplikasi dari blobs
            # Frame CCTV sebagai latar gambar jalur/heatmap/zona. Koordinatnya
            # sudah di ruang gambar kamera, jadi menempel persis.
            "frameLatar": uri_berkas(latar) if latar and latar.exists() else None,
            "pathVideo": uri_berkas(video) if ada_video else None,
            "overlayVideos": ([{"cam": (req.get("cameras") or [{}])[0].get("label", "Kamera 1"),
                                "uri": uri_berkas(video)}] if ada_video else []),
        },
        "trajectories": None,

        # -- di luar kontrak inti, lihat penjelasan di atas
        "extra": {
            "sumber": {**(mentah.get("sumber") or {}),
                       "lebar": lebar, "tinggi": tinggi},
            "occupancySatuan": mentah.get("occupancySatuan"),
            "blobs": mentah.get("blobs"),
            "paths": mentah.get("paths"),
            "grid": mentah.get("grid"),
            "jejak": mentah.get("jejak"),
            "jejakWaktu": mentah.get("jejakWaktu"),
            "jejakLangkah": mentah.get("jejakLangkah"),
            "totalVisitorsGalat": s.get("totalVisitorsGalat"),
            "avgDwellGalat": s.get("avgDwellGalat"),
            "galatSumber": s.get("galatSumber"),
            "captureRateVenueIni": s.get("captureRateVenueIni"),
            "diagnostik": mentah.get("diagnostik"),
            "folder": str(dirjob),
            "catatan": catatan,
        },
    }


# -------------------------------------------------------------- pelayanan

JOBS: dict[str, Job] = {}
JOBS_KUNCI = threading.Lock()


# ---------------------------------------------------------------- riwayat

def _aman(nama: str) -> Path | None:
    """Folder lari dari namanya, menolak nama yang menjangkau keluar."""
    if "/" in nama or nama in ("", ".", "..") or not nama.startswith("run-"):
        return None
    p = (KELUARAN / nama).resolve()
    return p if p.is_dir() and KELUARAN.resolve() in p.parents else None


def berkas_utama(d: Path) -> Path | None:
    """hasil.json lari itu — di akar untuk satu kamera, di `kamera-1/` untuk
    lari multi-kamera."""
    for kandidat in (d / "hasil.json", d / "kamera-1" / "hasil.json"):
        if kandidat.is_file():
            return kandidat
    return None


def daftar_lari() -> list[dict]:
    """Ringkasan tiap lari yang tersimpan, terbaru dulu.

    Isinya sengaja ringkas — layar Riwayat hanya perlu ini untuk menggambar
    kartunya, dan membaca seluruh hasil (termasuk grid 120x68 dan jejak) untuk
    setiap kartu akan berat tanpa guna."""
    out = []
    if not KELUARAN.is_dir():
        return out
    for d in KELUARAN.glob("run-*"):
        f = berkas_utama(d)
        if f is None:
            continue                       # folder separuh jadi
        try:
            m = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        s = m.get("sumber") or {}
        fps = float(s.get("fps_sumber") or 0) or 1.0
        # rglob, bukan iterdir: lari multi-kamera menyimpan tiap sudut di
        # subfoldernya sendiri, dan besarnya harus ikut terhitung.
        besar = sum(p.stat().st_size for p in d.rglob("*") if p.is_file())
        n_cam = max(1, len(list(d.glob("kamera-*"))))
        out.append({
            "id": d.name,
            "video": s.get("video") or d.name,
            # Tanpa pecahan detik: ISO8601DateFormatter di Swift menolak
            # "…:10.123456+00:00" secara bawaan, dan tanggal yang gagal dibaca
            # jatuh diam-diam ke tahun 1 — seluruh kartu Riwayat memperlihatkan
            # waktu yang ngawur tanpa satu pun pesan galat.
            "waktu": datetime.fromtimestamp(f.stat().st_mtime, timezone.utc)
                             .replace(microsecond=0).isoformat(),
            "frameDiproses": int(s.get("frame_diproses") or 0),
            "detik": round(float(s.get("frame_diproses") or 0) / fps, 1),
            "peakOccupancy": int((m.get("summary") or {}).get("peakOccupancy") or 0),
            "totalVisitors": int((m.get("summary") or {}).get("totalVisitors") or 0),
            "ukuranByte": besar,
            "adaVideo": bool(list(d.rglob("beranotasi.mp4"))),
            "jumlahKamera": n_cam,
        })
    return sorted(out, key=lambda r: r["waktu"], reverse=True)


def pakai_profil(isi_job: dict, profil_path: str) -> None:
    """Ganti titik kalibrasi tiap kamera dengan titik dari profil aplikasi.

    Profil menyimpan PIKSEL — titik kamera relatif ukuran frame saat
    dikalibrasi, titik lantai relatif ukuran gambar denah — sementara job
    memakai 0-1. Ukuran frame di profil pun bisa berbeda dari videonya (profil
    ini dibuat pada 4608x2592 sementara videonya 2304x1296), jadi menyalin
    piksel apa adanya akan menggeser semua titik dua kali lipat.
    """
    try:
        prof = json.loads(Path(profil_path).read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"[engine] profil kalibrasi tidak terbaca ({e}) — pakai titik dari aplikasi",
              flush=True)
        return

    dw = prof["floorplan"]["pixel_size"]["width"]
    dh = prof["floorplan"]["pixel_size"]["height"]
    for i, cam in enumerate(isi_job["cameras"]):
        if i >= len(prof.get("cameras") or []):
            print(f"[engine] profil cuma punya {len(prof.get('cameras') or [])} "
                  f"kamera — kamera {i+1} tetap memakai titik dari aplikasi", flush=True)
            continue
        pc = prof["cameras"][i]
        kal = pc["calibration"]
        fw, fh = pc["image_size"]["width"], pc["image_size"]["height"]
        cam["imagePoints"] = [{"x": p[0] / fw, "y": p[1] / fh}
                              for p in kal["camera_points_px"]]
        cam["planePoints"] = [{"x": p[0] / dw, "y": p[1] / dh}
                              for p in kal["floor_points_px"]]
        print(f"[engine] {cam.get('label')}: {len(cam['imagePoints'])} titik "
              f"dari profil kalibrasi", flush=True)
    isi_job["venue"] = {**isi_job.get("venue", {}),
                        "widthM": prof["world_bounds_m"]["width"],
                        "heightM": prof["world_bounds_m"]["height"]}


def salin_profil(profil_path: Path, dirjob: Path, n_kamera: int) -> None:
    """Taruh profil kalibrasi + denahnya di tiap folder kamera.

    Denahnya DISALIN, tidak dirujuk di tempat asalnya: aplikasi berjalan di
    kotak pasir dan cuma boleh membaca Documents/crowdflow. Menunjuk ke
    ~/Downloads gagal diam-diam, dan yang terlihat cuma panel denah kosong.
    """
    try:
        prof = json.loads(profil_path.read_text())
    except (OSError, json.JSONDecodeError):
        return

    # Skema 2 menyimpan denah sebagai berkas di sebelah profil; aplikasi ini
    # membacanya lewat image_path atau gambar yang disematkan.
    nama = (prof.get("floorplan") or {}).get("asset_file_name")
    sumber = profil_path.parent / nama if nama else None
    for i in range(1, n_kamera + 1):
        sub = dirjob / f"kamera-{i}"
        if not sub.is_dir():
            continue
        salinan = None
        if sumber and sumber.is_file():
            salinan = sub / sumber.name
            salinan.write_bytes(sumber.read_bytes())
        p = dict(prof)
        p["floorplan"] = {**(prof.get("floorplan") or {}),
                          "uses_canvas": False}
        if salinan:
            p["floorplan"]["image_path"] = str(salinan)
            p["floorplan"]["image_data"] = base64.b64encode(
                salinan.read_bytes()).decode()
        (sub / "kalibrasi.json").write_text(json.dumps(p))


def satukan_video(kamera: list[dict], utama: dict) -> None:
    """Kumpulkan video semua sudut ke daftar tingkat-atas, dengan label benar.

    `utama` selalu salinan kamera pertama, jadi tanpa ini yang terdaftar cuma
    satu sudut — video kamera kedua tetap dirender puluhan MB ke disk tapi tidak
    pernah bisa dibuka dari layar Hasil. Labelnya juga diambil dari tiap kamera
    sendiri; sebelumnya semua memakai label kamera pertama, sehingga dua sudut
    yang berbeda muncul dengan nama yang sama.
    """
    semua = []
    for k in kamera:
        seni = k.get("artifacts") or {}
        nama = k.get("label") or "Kamera"
        benar = [{"cam": nama, "uri": v["uri"]}
                 for v in (seni.get("overlayVideos") or []) if v.get("uri")]
        seni["overlayVideos"] = benar
        semua += benar
    if semua:
        utama["artifacts"] = {**(utama.get("artifacts") or {}),
                              "overlayVideos": semua}


def baca_lari(nama: str) -> dict | None:
    """Hasil lengkap satu lari lama, dalam bentuk yang sama dengan /jobs/<id>/result."""
    d = _aman(nama)
    if d is None:
        return None
    # Lari multi-kamera: tiap sudut punya subfoldernya sendiri, dan semuanya
    # harus ikut dikembalikan — kalau tidak, membuka lari lama diam-diam
    # kehilangan kamera kedua.
    subs = sorted(d.glob("kamera-*"))
    if subs:
        kamera = [x for x in (baca_satu(nama, s) for s in subs) if x]
        if not kamera:
            return None
        utama = dict(kamera[0])
        utama["cameras"] = kamera
        utama["gabungan"] = gabungkan(kamera)
        satukan_video(kamera, utama)
        return utama
    return baca_satu(nama, d)


def baca_satu(nama: str, d: Path) -> dict | None:
    """Hasil satu sudut kamera dari foldernya."""
    f = d / "hasil.json"
    if not f.is_file():
        return None
    try:
        m = json.loads(f.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    latar = d / "latar.jpg"
    # Ukuran frame tidak tercatat di hasil.json lama; dibaca dari berkas latar
    # kalau ada, kalau tidak dibiarkan 0 dan aplikasi memakai 16:9.
    lebar = tinggi = 0
    if latar.is_file():
        try:
            import cv2
            img = cv2.imread(str(latar))
            if img is not None:
                tinggi, lebar = img.shape[:2]
        except Exception:                                    # noqa: BLE001
            pass
    # Venue harus lengkap: sisi Swift mendekodenya sebagai bidang wajib, dan
    # objek kosong membuat SELURUH respons gagal dibaca tanpa pesan apa pun.
    # Detail venue tidak ikut tersimpan di hasil.json, jadi diisi seadanya.
    req = {"venue": {"widthM": 0.0, "heightM": 0.0,
                     "name": (m.get("sumber") or {}).get("video") or nama,
                     "type": "tidak tercatat"},
           "mode": "cepat", "cameras": [{"label": "Kamera 1"}]}
    hasil = petakan(nama, req, m, d, 1, lebar, tinggi,
                    latar if latar.is_file() else None)
    # Nama sudut seperti yang diketik pengguna, kalau sempat tersimpan.
    bawaan = ("Kamera " + d.name.split("-")[-1]) if d.name.startswith("kamera-") else "Kamera 1"
    try:
        hasil["label"] = json.loads((d / "kamera.json").read_text()).get("label") or bawaan
    except (OSError, json.JSONDecodeError):
        hasil["label"] = bawaan
    return hasil


class Handler(BaseHTTPRequestHandler):
    server_version = "CrowdFlowEngine/1.0"

    # Log bawaan menulis tiap permintaan ke stderr; /progress dijajaki tiap
    # setengah detik, jadi tanpa ini konsolnya tidak terbaca lagi.
    def log_message(self, fmt, *args):
        pass

    # -- utilitas
    def _kirim(self, kode: int, isi: dict):
        raw = json.dumps(isi).encode()
        self.send_response(kode)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        # Supaya versi web nanti bisa memanggil dari origin lain.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(raw)

    def _galat(self, kode: int, pesan: str):
        self._kirim(kode, {"error": pesan})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    # -- rute
    def do_GET(self):
        ruas = [r for r in urllib.parse.urlparse(self.path).path.split("/") if r]

        if ruas == ["health"]:
            return self._kirim(200, {"status": "ok", "device": perangkat()})

        if ruas == ["jobs"]:
            with JOBS_KUNCI:
                return self._kirim(200, {"jobs": [j.ringkas() for j in JOBS.values()]})

        # Riwayat: lari yang tersimpan di disk, termasuk dari sesi sebelumnya.
        # Dibaca dari berkas, bukan dari JOBS, supaya hasil tidak hilang setiap
        # server atau aplikasi dinyalakan ulang.
        if ruas == ["runs"]:
            return self._kirim(200, {"runs": daftar_lari()})

        if len(ruas) == 3 and ruas[0] == "runs" and ruas[2] == "result":
            hasil = baca_lari(ruas[1])
            if hasil is None:
                return self._galat(404, "lari tidak ditemukan")
            return self._kirim(200, hasil)

        if len(ruas) == 2 and ruas[0] == "runs":
            return self._galat(404, "rute tidak dikenal")

        if len(ruas) == 3 and ruas[0] == "jobs":
            job = JOBS.get(ruas[1])
            if not job:
                return self._galat(404, "job tidak dikenal")
            if ruas[2] == "progress":
                return self._kirim(200, job.ringkas())
            if ruas[2] == "result":
                if job.status == "error":
                    return self._galat(500, job.error or "job gagal")
                if job.status != "done" or job.result is None:
                    return self._galat(409, "job belum selesai")
                return self._kirim(200, job.result)

        if len(ruas) == 3 and ruas[0] == "files":
            return self._berkas(ruas[1], ruas[2])

        self._galat(404, "rute tidak dikenal")

    def do_POST(self):
        ruas = [r for r in urllib.parse.urlparse(self.path).path.split("/") if r]

        if ruas == ["jobs"]:
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, json.JSONDecodeError) as e:
                return self._galat(400, f"body bukan JSON yang sah: {e}")

            jid = uuid.uuid4().hex[:12]
            job = Job(jid, req)
            with JOBS_KUNCI:
                JOBS[jid] = job
            threading.Thread(target=job.jalankan, name=f"job-{jid}", daemon=True).start()
            return self._kirim(201, {"jobId": jid})

        # Hapus satu lari beserta isinya. Tiap lari menyimpan video beranotasi
        # 2–13 MB, dan rekaman itu memuat wajah karyawan — bisa dibersihkan itu
        # penting, bukan sekadar rapi.
        if len(ruas) == 3 and ruas[0] == "runs" and ruas[2] == "delete":
            d = _aman(ruas[1])
            if d is None:
                return self._galat(404, "lari tidak ditemukan")
            shutil.rmtree(d, ignore_errors=True)
            return self._kirim(200, {"dihapus": ruas[1]})

        # Tanya-jawab atas satu lari. Konteksnya disusun ulang tiap permintaan
        # (murah — cuma membaca satu JSON), jadi jawaban selalu mengikuti hasil
        # terbaru tanpa perlu menyalakan ulang server.
        if ruas == ["chat"]:
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, json.JSONDecodeError) as e:
                return self._galat(400, f"body bukan JSON yang sah: {e}")
            tanya_teks = (req.get("pertanyaan") or "").strip()
            if not tanya_teks:
                return self._galat(400, "pertanyaan kosong")
            run_id = req.get("runId") or ""
            if not run_id or _aman(run_id) is None:
                return self._galat(404, "lari tidak ditemukan")
            try:
                sys.path.insert(0, str(APP / "experiments"))
                import chatbot_konteks as ck
                # Lari pembanding disaring dulu lewat _aman(): namanya datang
                # dari luar, dan tanpa itu "../.." bisa dipakai membaca berkas
                # di luar folder hasil.
                lain = [r for r in (req.get("bandingkan") or [])
                        if isinstance(r, str) and _aman(r) is not None and r != run_id]
                konteks = ck.susun_konteks(run_id, lain)
                jawab = ck.tanya(tanya_teks, req.get("model") or "qwen3:8b",
                                 konteks, req.get("riwayat") or [])
            except urllib.error.URLError:
                # Bedakan dari galat lain: ini satu-satunya kegagalan yang bisa
                # diperbaiki sendiri oleh pemakai, dan pesannya harus menyebut
                # caranya — bukan "koneksi ditolak".
                return self._galat(503, "Ollama belum jalan. Buka Terminal, "
                                        "jalankan: ollama serve")
            except Exception as e:
                return self._galat(500, f"chat gagal: {e}")
            # qwen3 menyisipkan penalarannya di <think>…</think>; itu bocoran
            # dapur, bukan jawaban.
            if "</think>" in jawab:
                jawab = jawab.split("</think>")[-1]
            return self._kirim(200, {"jawaban": jawab.strip()})

        if len(ruas) == 3 and ruas[0] == "jobs" and ruas[2] == "cancel":
            job = JOBS.get(ruas[1])
            if not job:
                return self._galat(404, "job tidak dikenal")
            job.batal()
            return self._kirim(200, job.ringkas())

        self._galat(404, "rute tidak dikenal")

    def _berkas(self, jid: str, nama: str):
        """Sajikan hasil lewat HTTP juga, bukan hanya file://.

        Aplikasi macOS membaca berkasnya langsung, jadi jalur ini belum
        terpakai — tapi peramban tidak boleh membaca file://, dan tanpa
        endpoint ini versi web nanti tidak punya cara menampilkan videonya."""
        job = JOBS.get(jid)
        if not job:
            return self._galat(404, "job tidak dikenal")
        # Cegah "../.." menjangkau berkas di luar folder job.
        p = (job.dir / nama).resolve()
        if job.dir.resolve() not in p.parents or not p.is_file():
            return self._galat(404, "berkas tidak ada")

        tipe = {".mp4": "video/mp4", ".json": "application/json",
                ".png": "image/png", ".jpg": "image/jpeg"}.get(p.suffix, "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", tipe)
        self.send_header("Content-Length", str(p.stat().st_size))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        with p.open("rb") as f:
            shutil.copyfileobj(f, self.wfile)


def main():
    if not Path(PYTHON).exists():
        sys.exit(f"python venv tidak ada: {PYTHON}")
    if not SKRIP.exists():
        sys.exit(f"pipeline tidak ada: {SKRIP}")
    KELUARAN.mkdir(parents=True, exist_ok=True)

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"CrowdFlow engine di http://{HOST}:{PORT}")
    print(f"  python   : {PYTHON}")
    print(f"  pipeline : {SKRIP}")
    print(f"  keluaran : {KELUARAN}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nberhenti.")


if __name__ == "__main__":
    main()
