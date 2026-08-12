# Tanya Data — chatbot untuk hasil analisis

Tab di aplikasi untuk menanyai hasil analisis dengan bahasa biasa:

> **T:** tempat mana yang cocok buat main board game?
> **J:** Meja tengah paling cocok, karena orang berhenti paling lama di sana.

Jalan **lokal**, tanpa internet dan tanpa API berbayar.

## Pasang (sekali)

```bash
brew install ollama          # atau unduh dari https://ollama.com
ollama serve                 # biarkan jalan di Terminal terpisah
ollama pull qwen3:8b         # ~5 GB, sekali saja
```

## Jalankan

```bash
./llm/jalankan.sh            # layanan chat di :8766
```

Skrip itu memeriksa syaratnya dulu dan berhenti dengan pesan jelas kalau ada
yang kurang. Analisisnya sendiri tetap dijalankan engine di `:8765` seperti
biasa — layanan ini terpisah dan tidak menyentuhnya.

Kalau layanan ini mati, aplikasi tetap normal; cuma tab Tanya Data yang
menampilkan pesan.

## Uji

```bash
python3 llm/uji_chatbot.py <nama-riwayat>
```

31 soal, termasuk jebakan (angka palsu, pertanyaan di luar data, desakan dua
giliran). Kunci jawabannya **dihitung dari data**, bukan ditulis tangan — kalau
ditulis tangan, ujian ikut usang begitu datanya berubah, dan lebih buruk lagi
bisa meluluskan jawaban yang salah.

## Cara kerjanya

```
result.json  ->  susun_konteks()  ->  prompt  ->  qwen3:8b  ->  jawaban
   (riwayat)       + hitungan Python
```

Bukan RAG. Konteksnya ~1 KB, jadi seluruhnya ditempel ke prompt tiap pertanyaan
— tidak ada pencarian, tidak ada embedding, tidak ada basis data.

**Dua keputusan yang menentukan kualitas jawabannya, dan keduanya bukan soal
model:**

**1. Perbandingan angka dikerjakan Python.** Saat mencari nilai tertinggi dan
mengurutkan masih diserahkan ke model, dia salah baca puncak (16 dibaca 13) dan
membalik perbandingan (177 vs 83). Setelah dipindah ke Python dan hasilnya
ditulis sebagai kalimat "KESIMPULAN", semua soal uji lulus — tanpa model yang
lebih besar.

**2. Nama tempat dari zona yang digambar pemakai.** Nama yang ditebak program,
atau diketik dari melihat denah, hanya benar untuk satu ruangan. Versi ketikan
tangan meleset 0,8 meter di ruangan yang kami ukur.

> Gambar zona mengikuti meja lalu beri nama di layar Kalibrasi. Tanpa itu
> chatbot akan bilang zonanya belum digambar — bukan menebak nama meja.

## Yang sudah pernah salah, dan penjagaannya

Semua ini ditemukan lewat pemakaian sungguhan, bukan lewat soal yang dirancang:

| Pernah terjadi | Penjagaannya sekarang |
|---|---|
| "Zona A (meja panjang tengah)" — pemetaan yang tidak ada di data mana pun | zona kisi dan zona bernama dijelaskan terpisah; dilarang disamakan |
| Lorong disarankan sebagai tempat duduk karena paling sepi | hanya zona bernama yang muncul sebagai tempat |
| "588 detik-orang" dibantah model sendiri di giliran berikutnya | 6 giliran terakhir ikut dikirim |
| Menyetujui angka palsu dari pemakai | aturan: periksa ulang ke data sebelum mengalah |
| "data yang aku beri sudah akurat 😊" | emoji dan klaim akurat dibuang oleh kode, bukan cuma dilarang |
| Angka mentah dua rekaman dibandingkan langsung | perbandingan selalu per menit, panjang rekaman ikut disebut |

Pola yang berulang: **fakta yang hilang tidak membuat model diam — dia
mengisinya sendiri.** Hampir semua halusinasi di atas hilang setelah faktanya
ditulis eksplisit ke konteks, bukan setelah larangannya dipertegas.

## Menyetel

| Berkas / baris | Ubah kalau… |
|---|---|
| `konteks.py` → `ATURAN` | jawabannya kepanjangan, terlalu teknis, salah sikap |
| `konteks.py` → `susun_konteks()` | ada data yang belum sampai ke model |
| `konteks.py` → `MIN_PORSI` | tempat sekecil remah masih ikut disebut |
| `CHATBOT_MODEL=` | ganti model |
| `CHATBOT_BERPIKIR=1` | nyalakan mode berpikir qwen3 (jawaban 2x lebih lambat) |

Sesudah mengubah apa pun, **jalankan ujinya lagi**. Aturan yang kelihatan sepele
pernah membuat chatbot menempelkan peringatan di semua jawaban.
