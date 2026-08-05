# Bagian Re-ID — cara mencoba & temuan

## Model Re-ID: tidak ada berkas yang perlu dicari

`osnet_ain_x1_0_msmt17` adalah bobot bawaan BoxMOT. **Tidak perlu diunduh manual,
tidak ada berkas yang dikirim** — cukup sebut namanya, BoxMOT mengunduh sendiri
(~17 MB) saat pertama dijalankan. Waktu itu terjadi akan muncul `Downloading...`;
itu normal dan cuma sekali.

Yang **harus diminta ke Fitri**: `yolo11s_crowd.pt` (19 MB, detektornya), taruh di
`ml/weights/`. Itu hasil fine-tune dan tidak tersedia di mana pun lagi.

## Cara mencoba (5 menit)

```bash
pip install ultralytics boxmot
python jalankan.py video.mp4 --mulai 600 --frame 900
```

Keluarannya `keluaran.mp4` — video dengan kotak dan nomor ID tiap orang.

**Butuh satu berkas yang TIDAK ada di repo ini: `yolo11s_crowd.pt`** (19 MB,
detektor hasil fine-tune). Sengaja tidak di-commit supaya repo tetap ringan —
minta langsung ke Fitri, lalu taruh di `ml/weights/yolo11s_crowd.pt`.

Model Re-ID (`osnet_ain_x1_0_msmt17`) terunduh otomatis saat pertama jalan,
~17 MB — itu tidak perlu diminta.

### Atau tempelkan ke kode sendiri

Kalau tidak mau memakai `jalankan.py`, pakai `crowdflow.py` — dua fungsi saja:

```python
from crowdflow import buat_pipeline, lacak

det, trk = buat_pipeline()             # sekali di awal
for frame in video:
    hasil = lacak(det, trk, frame)     # tiap frame, BGR dari cv2
    # hasil: array (N, 8) -> x1, y1, x2, y2, id, conf, cls, idx
```

Seluruh setelan (conf 0,25 · threshold 0,25 · prox 0,9 · appear 0,6) sudah
tertanam di dalamnya. Satu tracker untuk satu video — kalau memproses dua kamera,
buat dua tracker terpisah.

Butuh GPU untuk kecepatan wajar. Di Apple M-series (MPS) sekitar **6-7 fps** pada
frame 2304x1296 — video 20 fps berarti pemrosesan ~3x lebih lambat dari waktu
nyata. Cocok untuk analisis rekaman, bukan tampilan langsung.

---


## Empat grafik

### `1_map_vs_idf1.png` — temuan utama
Tiap titik satu model. Sumbu X **mAP** (ujian pencarian), sumbu Y **IDF1** (ujian
tracking). Hubungannya **menurun**, korelasi −0,68: model dengan mAP tertinggi
justru IDF1-nya terendah.

CLIP-ReID mAP 49,0 → IDF1 42,05. OSNet x0.25 mAP 9,1 → IDF1 44,55.

Sebabnya mekanis: **mAP menilai urutan, tracker butuh garis batas.** Tracker tidak
bertanya "siapa paling mirip di galeri", tapi "apakah kemiripan ini di atas
ambang?". Model bisa mengurutkan dengan benar tapi semua skornya berdempetan,
sehingga tidak ada ambang yang memisahkan.

### `2_tuas_pagar.png` — yang benar-benar menentukan
Tanpa Re-ID 39,0 → pagar bawaan 40,1 → pagar dibuka 49,8.

**Membuka pagar: +9,7 poin. Mengganti model: +1 poin.** Sepuluh kali lipat, dan
pagar cuma satu baris konfigurasi (`proximity_thresh` 0,5→0,9,
`appearance_thresh` 0,25→0,4).

Pagar bawaan mematikan Re-ID justru saat paling dibutuhkan: penampilan diabaikan
kalau kotak tidak tumpang tindih rapi — padahal saat oklusi kotaknya memang
berantakan.

### `3_daya_pisah.png` — kenapa model bisa gagal di satu domain
Kemiripan cosine antar crop pantry, orang sama versus orang berbeda:

- CLIP-ReID: 0,919 → 0,952, **selisih 0,033**
- OSNet-AIN: 0,465 → 0,662, **selisih 0,197**

Enam kali lipat. Jarak antar dua titik itu adalah ruang untuk menaruh garis batas;
makin sempit, makin sulit tracker memutuskan.

Catatan jujur: percobaan pertama menyimpulkan "Re-ID tidak berguna di pantry" —
padahal yang diuji baru CLIP-ReID. Kesimpulan tentang **satu model** dipakai
menghakimi **satu domain**. Setelah diuji model lain, kesimpulannya berubah.

### `4_batas_derau.png` — kenapa peringkat tidak sah
Titik = IDF1 di 7 kamera, garis = rata-rata. Simpangan baku selisih antar kamera
3,57 → galat baku 1,35 → **selisih di bawah 2,7 poin tidak bermakna**.

Empat model teratas (47,4 sampai 44,5) semuanya di dalam pita itu — **tidak dapat
diperingkat**. Hanya CLIP-ReID yang terpisah nyata, tertinggal 5,3 poin.

Jadi klaim yang bisa dipertahankan bukan "model X terbaik", melainkan: *pilihan
model hampir tidak berpengaruh kecuali CLIP-ReID yang jelas lebih buruk; yang
menentukan adalah cara memasangnya.*

---

## Bobot Re-ID: TIDAK PERLU DIKIRIM

Yang dipakai **`osnet_ain_x1_0_msmt17`** — bobot bawaan BoxMOT, terunduh
otomatis saat pertama dipanggil. Tidak ada berkas yang perlu disertakan.

```python
from boxmot.reid.core.reid import ReID
ext = ReID("osnet_ain_x1_0_msmt17.pt", device="mps", half=False).model
tracker = BotSort(reid_model=ext, proximity_thresh=0.9, appearance_thresh=0.6,
                  with_reid=True, ...)
```

Fine-tune Re-ID di domain pantry sudah dicoba **dua kali** dan keduanya tidak
terbukti membaik — rinciannya di notebook bagian 4. Bobot hasilnya tidak
disertakan karena tidak ada alasan memakainya.

Yang **wajib** disertakan justru detektornya: `weights/yolo11s_crowd.pt`.
Itu fine-tune yang tidak tersedia di mana pun selain di sini.



| | |
|---|---|
| menjaga ID dalam satu kamera | ⚠️ mayoritas terjaga, sebagian pecah saat berpapasan |
| ID sama di dua kamera | ❌ 20% benar terhadap anotasi manusia (acak ~3%) |
| jumlah orang, heatmap, okupansi | tidak bergantung Re-ID sama sekali |

---

## Setelan yang wajib ikut

```
conf detektor      0,25    (di 0,60 recall cuma 0,358 — dua pertiga pengunjung hilang)
threshold tracker  0,25    (diselaraskan dengan conf detektor)
proximity_thresh   0,9     ← di sini letak +9,7 poin
appearance_thresh  0,6
```

Detail lengkap dan semua angka: `crowdflow_inti/4_penerapan_pantry.ipynb`.
