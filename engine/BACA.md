# Engine CrowdFlow

Backend aplikasi `foodcourt`. Sebuah **server HTTP di localhost** (Python,
pustaka standar saja) yang membungkus pipeline deteksi + pelacakan + Re-ID.
Aplikasi Swift tidak pernah memanggil Python langsung — ia hanya bicara HTTP ke
`127.0.0.1:8765`, jadi kalau nanti engine-nya pindah ke server sungguhan atau
dipakai dari web, sisi aplikasinya tidak perlu diubah sama sekali.

```
foodcourt (Swift)  ──HTTP──►  engine/server/server.py  ──subprocess──►  pipeline
```

## Menjalankan

```bash
# dari akar repo
CROWDFLOW_PYTHON=/path/ke/python python3 engine/server/server.py
```

Lalu buka aplikasinya. Kalau engine mati, aplikasi menampilkan
"pastikan engine jalan di :8765" dan tidak lebih — ia tidak akan macet.

Setelan lewat variabel lingkungan:

| Variabel | Bawaan | Guna |
|---|---|---|
| `CROWDFLOW_PYTHON` | `<akar repo>/venv_boxmot/bin/python` | Python yang punya ultralytics & boxmot |
| `CROWDFLOW_HOST` | `127.0.0.1` | alamat dengar |
| `CROWDFLOW_PORT` | `8765` | porta |

Hasil ditulis ke `~/Documents/crowdflow/run-<id>/`, dan dari situ pula layar
Riwayat membacanya.

## Yang TIDAK ada di repo ini

Dua hal sengaja tidak ikut, dan tanpa keduanya server tetap jalan tapi tidak
bisa memproses video baru:

1. **`engine/weights_ft/yolo11s_crowd.pt`** (19 MB) — bobot detektor hasil
   fine-tune. Salin manual ke `engine/weights_ft/`.
2. **Rekaman CCTV.** Rekaman pantry memuat wajah karyawan dan tidak boleh
   masuk repo mana pun. Videonya dipilih lewat dialog Import di aplikasi dan
   dibaca dari luar repo; tidak pernah disalin ke dalam proyek.

Bobot Re-ID (`osnet_ain_x1_0_msmt17.pt`) diunduh sendiri oleh boxmot saat
pertama dipakai.

## Lingkungan Python

Pipeline butuh `ultralytics`, `boxmot`, `opencv-python`, `numpy`, `scipy`,
dan `torch` (MPS di Apple Silicon). `server.py` sendiri **tidak butuh apa-apa**
di luar pustaka standar — kalau yang ingin dilihat cuma hasil lari lama lewat
Riwayat, `python3 engine/server/server.py` polos sudah cukup.

## Kontrak HTTP

| Metode | Lintasan | Guna |
|---|---|---|
| GET | `/health` | engine hidup? perangkat apa (mps/cpu)? |
| POST | `/jobs` | mulai analisis; badan JSON berisi daftar video |
| GET | `/jobs/<id>/progress` | 0–1 plus nama tahap |
| GET | `/jobs/<id>/result` | hasil lengkap |
| POST | `/jobs/<id>/cancel` | batalkan |
| GET | `/files/<id>/<nama>` | ambil berkas keluaran (video beranotasi, frame latar) |
| GET | `/runs` | daftar lari lama, untuk layar Riwayat |
| GET | `/runs/<id>/result` | hasil satu lari lama |
| POST | `/runs/<id>/delete` | hapus satu lari |

Kemajuan dilaporkan pipeline lewat baris `PROGRESS <tahap> <frac>` di stdout,
dan `server.py` yang menerjemahkannya jadi angka 0–1.
