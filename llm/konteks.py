"""Susun konteks chatbot dari riwayat analisis yang disimpan aplikasi.

Membaca `result.json` bentuk `SavedAnalysis` — yang ditulis aplikasi sendiri ke
Application Support, bukan keluaran engine mana pun. Jadi layanan ini tidak
peduli siapa yang menjalankan analisis.

Dua keputusan yang menentukan kualitas jawabannya, keduanya di luar model:

1. PERBANDINGAN DIKERJAKAN PYTHON. Model tidak pernah diminta mencari nilai
   tertinggi atau mengurutkan; itu sudah jadi kalimat "KESIMPULAN" sebelum
   sampai ke prompt. Waktu masih diserahkan ke model, dia salah baca puncak
   (16 dibaca 13) dan membalik perbandingan (177 vs 83).

2. TEMPAT DINAMAI DARI ZONA YANG DIGAMBAR PEMAKAI (`customZones`). Nama yang
   ditebak program — atau lebih buruk, diketik programmer dari melihat denah —
   hanya benar untuk satu ruangan. Ketikan seperti itu meleset 0,8 meter di
   ruangan yang kami ukur, dan untuk ruangan lain akan salah total sambil
   terdengar sangat yakin.
"""
import json
import os
import re
import urllib.request
from datetime import datetime
from pathlib import Path

# Riwayat ditulis aplikasi ber-sandbox, jadi "Application Support" miliknya ada
# di dalam kontainer — bukan di ~/Library/Application Support.
KONTAINER = (Path.home() / "Library/Containers/com.tiara.foodcourt/Data"
             / "Library/Application Support/Foodcourt/history")
BIASA = Path.home() / "Library/Application Support/Foodcourt/history"
OLLAMA = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/chat")
MODEL = os.environ.get("CHATBOT_MODEL", "qwen3:8b")

# Mode berpikir qwen3 menulis ~800 karakter penalaran yang tidak pernah
# ditampilkan, dan memakan separuh waktu jawab (25 detik jadi 13). Dimatikan
# setelah uji lulus penuh di kedua setelan.
BERPIKIR = os.environ.get("CHATBOT_BERPIKIR", "0") != "0"

# Porsi di bawah ini tidak disebut: terlalu kecil untuk jadi temuan.
MIN_PORSI = 0.02

# Sifat yang tidak pernah diukur. Diperiksa pada jawaban, bukan cuma dilarang
# di prompt — larangan ditaati hampir selalu, dan "hampir" tetap meloloskan
# "meja tengah lebih nyaman untuk fokus".
# Yang dicari POLA KLAIM, bukan katanya. "Data tidak bisa menilai kenyamanan"
# itu justru sikap yang benar; melarang kata mentah menghukum kalimat yang
# sedang membantah.
KLAIM_TAK_TERUKUR = (
    "lebih nyaman", "paling nyaman", "nyaman untuk", "nyaman buat",
    "lebih adem", "lebih terang", "lebih bersih", "lebih estetik",
    "lebih sejuk", "cozy", "asyik untuk", "suasana santai",
)


# Jenis tempat ditebak DARI NAMANYA, karena zona bernama cuma menyimpan nama.
# Tanpa ini, "rak sisi kanan" ikut disarankan sebagai tempat duduk hanya karena
# angkanya kecil — sepi memang, sebab orang cuma lewat di sana.
KATA_DUDUK = ("meja", "sofa", "kursi", "bangku", "sofabed", "booth")
KATA_LAYANAN = ("konter", "kasir", "dapur", "wastafel", "cuci", "antre",
                "counter", "bar")
KATA_LEWAT = ("rak", "lorong", "jalan", "pintu", "koridor", "tangga", "lewat")


def jenis_zona(nama: str) -> str:
    n = nama.lower()
    if any(k in n for k in KATA_DUDUK):
        return "duduk"
    if any(k in n for k in KATA_LAYANAN):
        return "layanan"
    if any(k in n for k in KATA_LEWAT):
        return "lewat"
    return "tidak diketahui"


KETERANGAN_JENIS = {
    "duduk": "tempat duduk — boleh disarankan untuk duduk, belajar, board game",
    "lewat": "jalur orang lewat — JANGAN disarankan sebagai tempat duduk",
    "layanan": "area layanan, orang berdiri sebentar — BUKAN tempat nongkrong",
    "tidak diketahui": ("belum jelas tempat duduk atau bukan — jangan disarankan "
                        "sebagai tempat duduk tanpa menyebut ketidakpastian ini"),
}


def folder_riwayat() -> Path:
    return KONTAINER if KONTAINER.is_dir() else BIASA


def daftar_riwayat() -> list[str]:
    d = folder_riwayat()
    if not d.is_dir():
        return []
    berkas = [p for p in d.iterdir() if (p / "result.json").is_file()]
    berkas.sort(key=lambda p: (p / "result.json").stat().st_mtime, reverse=True)
    return [p.name for p in berkas]


def label_riwayat(nama: str) -> str:
    """Nama yang bisa dibaca orang untuk satu riwayat.

    Folder riwayat diberi nama UUID oleh aplikasi ("90B2B180-1BBC-46D9-..."),
    dan itu tidak memberi tahu apa pun tentang isinya. Dalam daftar berisi
    beberapa analisis, memilih yang benar jadi tebak-tebakan.
    """
    f = folder_riwayat() / nama / "result.json"
    try:
        d = json.loads(f.read_text())
        waktu = datetime.fromtimestamp(f.stat().st_mtime).strftime("%d %b %H:%M")
        return (f"{d.get('venueName') or 'Analisis'} · {waktu} · "
                f"{d.get('totalVisitors', 0)} orang · "
                f"{d.get('durationSec', 0):.0f} dtk")
    except (OSError, ValueError, KeyError):
        return nama


def muat(nama: str) -> dict:
    f = folder_riwayat() / nama / "result.json"
    return json.loads(f.read_text())


def _dalam(x: float, y: float, z: dict) -> bool:
    return z["x"] <= x <= z["x"] + z["w"] and z["y"] <= y <= z["y"] + z["h"]


def porsi_per_zona(d: dict) -> list[tuple[str, float]]:
    """Porsi waktu-orang di tiap zona bernama, dari titik-kaki mentah.

    `observations` sudah dijarangkan aplikasi (dibatasi ~5000 titik), jadi
    jumlah absolutnya TIDAK berarti detik. Yang sah cuma perbandingannya —
    karena itu dilaporkan sebagai porsi, bukan sebagai satuan waktu. Menyebutnya
    "detik" akan terdengar seperti pengukuran yang tidak pernah kami lakukan.
    """
    zona = d.get("customZones") or []
    obs = d.get("observations") or []
    if not zona or not obs:
        return []
    hitung = {z["name"]: 0 for z in zona}
    for titik in obs:
        if len(titik) < 2:
            continue
        x, y = titik[0], titik[1]
        for z in zona:
            if _dalam(x, y, z):
                hitung[z["name"]] += 1
                break
    total = sum(hitung.values()) or 1
    hasil = [(n, v / total) for n, v in hitung.items() if v]
    hasil.sort(key=lambda t: -t[1])
    return hasil


ATURAN = """\
Kamu asisten yang menjawab pertanyaan tentang hasil analisis kamera CCTV sebuah \
pujasera. Jawab dalam bahasa Indonesia sehari-hari, ringkas, maksimal 3 kalimat.

CARA MENULIS:
1. Tulis kalimat biasa. DILARANG memakai tanda **, #, -, *, atau penomoran.
   DILARANG memakai label seperti "Kesimpulan:", "Peringatan:", "Catatan:".
2. Sebut angka SESEDIKIT mungkin — paling banyak satu angka, dan hanya kalau
   pertanyaannya memang menanyakan angka. Untuk pertanyaan "di mana" atau
   "tempat mana", jawab NAMA TEMPATNYA saja tanpa angka.
3. Jangan mengulang peringatan yang tidak ditanyakan.

ISI:
4. Pakai HANYA fakta di DATA. Dilarang mengarang angka.
5. Bagian KESIMPULAN sudah dihitung dengan benar — percayai, jangan hitung ulang.
6. HANYA kalau pertanyaannya tentang jumlah orang atau puncak okupansi, tambahkan
   satu kalimat bahwa angkanya perkiraan. Selain itu, jangan disinggung.
7. Kalau ditanya yang tidak ada di DATA, katakan tidak tersedia. Jangan menebak.
8. Untuk pertanyaan "kenapa", awali "kemungkinan", dan hanya pakai fakta di DATA.
9. DILARANG menyebut colokan listrik, wifi, AC, pencahayaan, harga, menu, musik.
9b. DILARANG menyebut sifat yang tidak diukur: nyaman, adem, luas, bersih,
    estetik, cozy, santai, asyik. Yang kita punya cuma seberapa sering orang
    berada di sana.

KALAU PEMAKAI MERAGUKAN ANGKAMU:
10. Periksa lagi ke DATA sebelum menjawab. Kalau angkamu memang ada di DATA,
    pertahankan dan jelaskan artinya. Kalau tidak ada, akui salah.
11. DILARANG memakai emoji. DILARANG mengklaim datamu "akurat" atau "sudah
    jelas" — angka-angka ini perkiraan dari rekaman pendek.
12. Jangan minta maaf berlebihan dan jangan memuji pertanyaannya.
13. Zona kisi (A-F) dan zona bernama adalah DUA HAL BERBEDA. Zona kisi cuma
    membagi ruangan rata dan TIDAK mengikuti perabot; jangan menyamakannya
    dengan meja, dan jangan menyarankannya sebagai tempat.
14. Pertanyaan ANDAI-ANDAI ("kalau layoutnya diganti") paling gampang memancing
    karangan. Jawab HANYA dengan fakta terukur, lalu katakan selebihnya di luar
    jangkauan data.
15. Yang kita ukur cuma SEBERAPA LAMA ORANG BERADA di suatu tempat. Itu bisa
    menjawab kegiatan yang intinya berlama-lama sambil duduk: board game,
    catur, belajar, rapat, mengobrol, mengerjakan tugas.
    Itu TIDAK BISA menjawab kegiatan yang butuh peralatan atau fasilitas —
    masak, bikin jus, cuci piring, ngecas, olahraga, salat, tidur, rapat
    daring. Untuk yang seperti itu, katakan datanya tidak mencakup hal
    tersebut. JANGAN menempelkan kegiatan apa pun ke tempat yang paling ramai
    hanya karena tempat itu paling sering dipakai.
    JANGAN pula menebaknya dari NAMA zona. Nama cuma menandai jenis tempat
    secara kasar; kita tidak tahu ada peralatan apa di sana. "Konter" tidak
    berarti ada mesin jus, dan "meja" tidak berarti ada colokan.
"""


def susun_konteks(nama: str) -> str:
    d = muat(nama)
    b = ["=== FAKTA DASAR ==="]
    b.append(f"Ruangan {d.get('venueName','pujasera')} "
             f"{d.get('widthM',0):g} x {d.get('heightM',0):g} meter, "
             f"rekaman {d.get('durationSec',0):.0f} detik.")
    b.append(f"Orang terdeteksi: sekitar {d.get('totalVisitors',0)} "
             f"(perkiraan — deteksi tidak menangkap semua orang).")
    dwell = d.get("avgDwellSeconds", 0)
    menitnya = ("kurang dari 1 menit" if dwell < 60 else f"sekitar {dwell/60:.1f} menit")
    b.append(f"Rata-rata satu orang BERADA DI RUANGAN: {dwell} detik ({menitnya}). "
             f"Ini lama berada di ruangan, bukan lama duduk — kita tidak bisa "
             f"membedakan duduk dan berdiri.")
    b.append("")

    # ---- tempat, dari zona yang digambar dan dinamai pemakai ----
    porsi = porsi_per_zona(d)
    b.append("=== TEMPAT (zona yang kamu gambar sendiri di aplikasi) ===")
    if porsi:
        b.append("Angka = PORSI waktu-orang, bukan detik. Titik pengamatan sudah "
                 "dijarangkan, jadi yang sah cuma perbandingan antar tempat.")
        for n, p in porsi:
            if p >= MIN_PORSI:
                b.append(f"  {n}: {p*100:.0f}% dari total waktu-orang "
                         f"[{KETERANGAN_JENIS[jenis_zona(n)]}]")
        b.append("Jenis tempat ditebak dari NAMANYA. Kalau namanya tidak "
                 "menyebutkan jenisnya, kamu tidak tahu tempat itu bisa "
                 "diduduki atau tidak — katakan apa adanya.")
    else:
        b.append("BELUM ADA zona bernama. Buka aplikasi, gambar zona mengikuti "
                 "meja lalu beri nama, dan jalankan analisis lagi.")
        b.append("Karena itu kamu TIDAK TAHU nama tempat mana pun di ruangan ini. "
                 "Kalau ditanya 'di mana', jawab HANYA bahwa zonanya belum "
                 "digambar dan sarankan menggambarnya di layar Kalibrasi. "
                 "JANGAN menebak nama meja, dan JANGAN menyebut zona kisi "
                 "(A-F) sebagai gantinya — zona kisi cuma kotak yang membagi "
                 "ruangan rata, bukan tempat yang bisa ditempati orang. "
                 "Menyebutnya sebagai jawaban 'di mana' sama menyesatkannya "
                 "dengan menebak nama meja.")
    b.append("")

    # ---- zona kisi bawaan ----
    zones = d.get("zones") or []
    # Angka zona kisi DICABUT kalau belum ada zona bernama. Dengan zona bernama
    # tersedia, model memakai yang benar; tanpa itu, angka kisi jadi satu-satunya
    # yang terlihat seperti jawaban "di mana" — dan model memakainya walau
    # larangannya ditulis tepat di sebelahnya ("Zona kisi B adalah tempat yang
    # paling sering dikunjungi"). Mencabut umpannya lebih ampuh daripada
    # melarang memakannya.
    if zones and not porsi:
        b.append("=== ZONA KISI A-F ===")
        b.append("Ada 6 zona kisi, tapi angkanya SENGAJA tidak diberikan di "
                 "sini: kotak itu membagi ruangan rata dan tidak mengikuti "
                 "perabot, jadi tidak bisa menjawab 'di mana'. Kalau pemakai "
                 "bertanya soal zona kisi, katakan zonanya perlu digambar dan "
                 "dinamai dulu di layar Kalibrasi supaya angkanya berarti.")
        b.append("")
    elif zones:
        b.append("=== ZONA KISI A-F (dibagi rata, BUKAN perabot) ===")
        tertinggi = max(z["visits"] for z in zones)
        b.append(f"Angka di bawah jumlah SAMPEL, BUKAN jumlah orang. Zona dengan "
                 f"{tertinggi} sampel TIDAK berarti {tertinggi} orang — "
                 f"pengunjungnya cuma {d.get('totalVisitors',0)}.")
        for z in zones:
            b.append(f"  Zona {z['code']}: {z['visits']} sampel")
        # Peringatannya ditaruh DI SINI, menempel pada angkanya. Waktu larangan
        # ini cuma ada di bagian zona bernama, model tetap menjawab "tempat mana
        # yang cocok" dengan "Zona A dan B" — dia membaca angka di bagian ini
        # dan tidak menghubungkannya dengan larangan yang jauh di atas.
        b.append("JANGAN memakai zona kisi untuk menjawab 'di mana', 'tempat "
                 "mana', atau saran tempat duduk. Kotak ini tidak mengikuti "
                 "perabot — satu kotak bisa berisi setengah meja plus lantai "
                 "kosong. Sebut zona kisi HANYA kalau pemakai bertanya "
                 "khusus tentang 'zona'.")
        b.append("")

    # ---- keramaian per menit ----
    occ = d.get("occupancy") or []
    b.append("=== KERAMAIAN PER MENIT ===")
    if len(occ) < 3:
        b.append(f"  Rekaman ini cuma {len(occ)} menit — TERLALU PENDEK untuk "
                 f"menyimpulkan kapan ramai atau sepi.")
    else:
        for o in occ:
            b.append(f"  menit ke-{o['minute']}: {o['count']} orang")
    b.append("  Menit dihitung dari awal rekaman, bukan jam dinding — kita tidak "
             "tahu pukul berapa rekaman ini dibuat.")
    b.append("")

    # ---- KESIMPULAN: dihitung Python ----
    b.append("=== KESIMPULAN (sudah dihitung, percayai ini) ===")
    if len(occ) >= 3:
        ramai = max(occ, key=lambda o: o["count"])
        sepi = min(occ, key=lambda o: o["count"])
        beda = ramai["count"] - sepi["count"]
        # Selisih sekecil ini di bawah ketelitian deteksi; menyebutnya puncak
        # berarti melaporkan derau sebagai temuan.
        if beda <= 3 or beda < 0.2 * max(ramai["count"], 1):
            b.append(f"  Keramaian RATA: paling sepi {sepi['count']} orang, paling "
                     f"ramai {ramai['count']}. Selisih sekecil ini masih dalam "
                     f"ketelitian deteksi — TIDAK ADA menit yang menonjol.")
        else:
            b.append(f"  Paling ramai: menit ke-{ramai['minute']} ({ramai['count']} orang).")
            b.append(f"  Paling sepi: menit ke-{sepi['minute']} ({sepi['count']} orang).")
    if porsi:
        b.append(f"  Tempat paling sering ditempati: {porsi[0][0]} "
                 f"({porsi[0][1]*100:.0f}%).")
        b.append("  Urutan: " + ", ".join(f"{n} ({p*100:.0f}%)" for n, p in porsi))
        # Saran DISARING ke tempat duduk. Diurutkan angka saja, jawaban untuk
        # "di mana yang sepi" jatuh ke lorong — paling sedikit orang berhenti
        # di sana justru karena orang cuma lewat.
        duduk = [(n, p) for n, p in porsi if jenis_zona(n) == "duduk"]
        if duduk:
            b.append(f"  Paling cocok untuk berlama-lama (board game, belajar): "
                     f"{duduk[0][0]}.")
            b.append(f"  Tempat duduk paling sepi (untuk sendirian): {duduk[-1][0]}.")
        b.append("  Tempat berjenis 'lewat' dan 'layanan' TIDAK BOLEH disarankan "
                 "sebagai tempat duduk, sesepi apa pun angkanya.")
    b.append("")

    b.append("=== PERINGATAN YANG WAJIB DISAMPAIKAN ===")
    b.append(f"  Jumlah orang ({d.get('totalVisitors',0)}) perkiraan KASAR dan "
             f"cenderung berlebih: pelacakan kadang memberi identitas baru saat "
             f"orang tertutup. Sebutkan sebagai kisaran.")
    b.append(f"  'Puncak okupansi' ({d.get('peakOccupancy',0)}) dihitung PER MENIT "
             f"— berapa orang lewat dalam satu menit, BUKAN berapa orang duduk "
             f"bersamaan. Jangan sebut 'bersamaan'.")
    b.append("")

    b.append("=== YANG TIDAK DIUKUR ===")
    b.append("identitas orang, umur, jenis kelamin, apa yang dibeli, harga, menu, "
             "percakapan, cuaca, pendapatan, jam dinding, hari selain rekaman ini.")
    return "\n".join(b)


def bersihkan(teks: str) -> str:
    """Buang sisa Markdown, emoji, dan label yang lolos dari aturan.

    Larangan di prompt ditaati hampir selalu — dan "hampir" berarti satu jawaban
    dari dua puluh tetap keluar dengan bintang tebal atau senyum di ujung
    laporan analisis. Yang bisa dipastikan kode, jangan diserahkan ke model.
    """
    teks = teks.split("</think>")[-1]
    teks = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", teks)
    teks = re.sub(r"(?m)^\s*[-*•]\s+", "", teks)
    teks = re.sub(r"(?m)^\s*\d+[.)]\s+", "", teks)
    teks = re.sub(r"(?m)^\s*(Kesimpulan|Peringatan|Catatan|Jawaban)\s*:\s*", "", teks)
    teks = re.sub("[\U0001F300-\U0001FAFF\U00002600-\U000027BF️]", "", teks)
    teks = re.sub(r" {2,}", " ", teks).replace(" .", ".").replace(" ,", ",")
    return re.sub(r"\n{2,}", "\n", teks).strip()


def tanya(pertanyaan: str, konteks: str, riwayat=None, model: str = MODEL) -> str:
    """`riwayat`: [{"peran": "orang"|"bot", "teks": ...}] — giliran sebelumnya.

    Tanpa riwayat, pertanyaan susulan seperti "kok lama banget 588 detik?"
    dijawab tanpa tahu 588 itu dari mana, dan model menyangkal angkanya sendiri.
    """
    pesan = [{"role": "system", "content": ATURAN + "\n\nDATA:\n" + konteks}]
    for g in (riwayat or [])[-6:]:
        pesan.append({"role": "user" if g.get("peran") == "orang" else "assistant",
                      "content": g.get("teks", "")})
    pesan.append({"role": "user", "content": pertanyaan})
    payload = {"model": model, "stream": False,
               "options": {"temperature": 0.2}, "messages": pesan}
    if not BERPIKIR:
        payload["think"] = False
    jawab = bersihkan(_panggil(payload))

    # Kata sifat yang tidak pernah kami ukur tetap lolos sesekali walau sudah
    # dilarang dua kali di ATURAN ("meja tengah lebih nyaman untuk fokus").
    # Sekali diminta ulang dengan koreksi tegas biasanya cukup; kalau masih
    # lolos, jawaban tetap dikirim — lebih baik satu kata janggal daripada
    # pemakai menunggu tanpa jawaban.
    bocor = [k for k in KLAIM_TAK_TERUKUR if k in jawab.lower()]
    if bocor:
        payload["messages"] = payload["messages"] + [
            {"role": "assistant", "content": jawab},
            {"role": "user", "content":
                f"Kata {', '.join(bocor)} menyebut sifat yang tidak kita ukur. "
                f"Tulis ulang jawabanmu tanpa kata itu dan tanpa menggantinya "
                f"dengan sifat lain — cukup sebut seberapa sering orang berada "
                f"di sana."}]
        jawab = bersihkan(_panggil(payload))
    return jawab


def _panggil(payload: dict) -> str:
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)["message"]["content"]
