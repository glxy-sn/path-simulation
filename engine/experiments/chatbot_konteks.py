"""Susun konteks chatbot dari hasil analisis, plus tanya ke Ollama.

Dua keputusan yang menentukan kualitas jawabannya, keduanya bukan soal model:

1. PERBANDINGAN DIKERJAKAN PYTHON. Model tidak pernah diminta mencari nilai
   tertinggi atau mengurutkan — itu sudah jadi kalimat "KESIMPULAN" sebelum
   sampai ke prompt. Waktu masih diserahkan ke model, dia salah baca puncak
   (16 dibaca 13) dan membalik perbandingan (177 vs 83).

2. POSISI DITERJEMAHKAN JADI NAMA FURNITUR. "Stop 1" tidak berarti apa-apa buat
   orang; "meja panjang tengah" langsung berguna. Pemetaannya ditulis sekali di
   PETA_AREA di bawah, dibaca dari denah — bukan ditebak model tiap pertanyaan.

    python engine/experiments/chatbot_konteks.py "<pertanyaan>" [model] [run-id]
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

KELUARAN = Path.home() / "Documents/crowdflow"
OLLAMA = "http://localhost:11434/api/chat"

# Titik henti di bawah ini diabaikan: terlalu kecil untuk disebut tempat orang
# berlama-lama, dan cuma mengotori daftar.
MIN_DETIK_ORANG = 10

# Mode berpikir model, BAWAANNYA MATI. Nyalakan dengan CHATBOT_BERPIKIR=1.
#
# qwen3 menulis ~800 karakter penalaran yang tidak pernah ditampilkan, dan itu
# memakan separuh waktu jawab (25 detik jadi 13). Dimatikan setelah 25 soal uji
# lulus penuh di kedua setelan — bukan karena pikirannya tidak berguna, tapi
# karena untuk pertanyaan sesempit ini tidak terbukti mengubah jawaban.
BERPIKIR = os.environ.get("CHATBOT_BERPIKIR", "0") != "0"

# Kotak (x0, y0, x1, y1) dalam METER, dibaca dari denah lantai 10 x 7,5 m.
# Sumbu y menghadap ke bawah: y kecil = sisi sofa, y besar = sisi konter.
#
# JENIS menentukan tempat itu boleh disarankan atau tidak. Tanpa ini chatbot
# menyarankan "ruang terbuka antar meja" sebagai tempat sepi untuk sendirian —
# angkanya benar (paling sedikit orang berhenti di sana), sarannya konyol: itu
# lorong orang lewat. Angka saja tidak pernah bisa membedakan keduanya.
DUDUK, LEWAT, LAYANAN = "duduk", "lewat", "layanan"
PETA_AREA = [
    ("sofa panjang di sisi jendela", 1.5, 0.0, 7.0, 2.2, DUDUK),
    ("meja panjang kiri", 1.0, 3.0, 3.3, 6.0, DUDUK),
    ("meja panjang tengah", 3.6, 3.0, 5.6, 6.0, DUDUK),
    ("meja panjang kanan", 5.8, 3.0, 8.0, 6.0, DUDUK),
    ("rak di sisi kanan", 8.6, 1.5, 10.0, 6.5, LEWAT),
    ("konter di sisi bawah", 1.0, 6.6, 8.0, 7.5, LAYANAN),
]
KETERANGAN_JENIS = {
    DUDUK: "tempat duduk — boleh disarankan untuk duduk, belajar, board game",
    LEWAT: "jalur orang lewat — JANGAN disarankan sebagai tempat duduk",
    LAYANAN: ("area cuci piring, kulkas, mesin kopi, piring dan gelas, kadang "
              "jajanan — orang berdiri sebentar, BUKAN tempat nongkrong"),
}


def peta_perabot(run_id: str) -> list[tuple]:
    """Peta perabot untuk lari ini: dari `perabot.json` kalau ada.

    Berkas itu dihasilkan `perabot_dari_denah.py` — kotaknya diukur dari gambar
    denah, bukan diketik tangan. Kalau tidak ada, jatuh ke PETA_AREA bawaan yang
    HANYA benar untuk pujasera 10 x 7,5 m ini; ruangan lain akan diberi nama
    meja yang salah dengan penuh percaya diri.
    """
    # 1. Suntingan manusia, kalau ada — selalu menang.
    for f in [KELUARAN / run_id / "perabot.json"]:
        if not f.is_file():
            continue
        try:
            d = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            break
        peta = [(p["nama"], p["x0"], p["y0"], p["x1"], p["y1"],
                 p.get("jenis", LEWAT)) for p in d.get("perabot", [])]
        if peta:
            return peta

    # 2. Kalau tidak ada, ukur langsung dari gambar denah lari ini. Tiap lari
    #    yang diproses lewat aplikasi sudah punya kalibrasi.json + denahnya,
    #    jadi ini jalan tanpa berkas tambahan dan tanpa langkah manual — video
    #    baru cukup diproses seperti biasa.
    try:
        sys.path.insert(0, str(Path(__file__).parent))
        from perabot_dari_denah import peta_dari_lari
        peta = peta_dari_lari(run_id)
        if peta:
            return peta
    except Exception:                                        # noqa: BLE001
        pass

    # 3. Jalan terakhir: peta ketikan tangan, HANYA benar untuk pujasera ini.
    return PETA_AREA


def nama_tempat(x_m: float, y_m: float, peta: list[tuple] | None = None) -> str:
    """Nama furnitur terdekat, atau keterangan jujur kalau di luar ruangan."""
    if not (0 <= x_m <= 10 and 0 <= y_m <= 7.5):
        return "DI LUAR RUANGAN (kalibrasi meleset — abaikan titik ini)"
    for nama, x0, y0, x1, y1, _ in (peta or PETA_AREA):
        if x0 <= x_m <= x1 and y0 <= y_m <= y1:
            return nama
    return "ruang terbuka antar meja"


def jenis_tempat(nama: str, peta: list[tuple] | None = None) -> str:
    """duduk / lewat / layanan. Ruang sisa dianggap jalur lewat."""
    for n, _, _, _, _, jenis in (peta or PETA_AREA):
        if nama.startswith(n):
            return jenis
    return LEWAT


def bedakan(nama: str, x_m: float, y_m: float) -> str:
    """Tambahkan patokan arah, dipakai kalau dua titik bernama sama.

    Kalibrasi Tiara menghasilkan dua titik henti yang sama-sama jatuh di
    "ruang terbuka antar meja" (160 dan 3 detik-orang). Dua baris bernama
    persis sama dengan angka berbeda tidak bisa dirujuk siapa pun — model
    maupun orang yang bertanya.
    """
    return f"{nama} (posisi {x_m:.0f} m dari kiri, {y_m:.0f} m dari atas)"


def muat(sumber: str) -> dict:
    """Baca satu lari, ATAU satu berkas ekspor laporan, jadi bentuk yang sama.

    Dua format ini berbeda dalam hal yang penting: ekspor laporan menyimpan
    titik-berhenti TANPA koordinat, cuma "Stop 1". Tanpa koordinat, tidak ada
    cara menamainya jadi meja — jadi titik itu ditandai `tanpa_posisi` dan
    konteks akan mengatakan apa adanya, bukan mengarang nama.
    """
    p = Path(sumber).expanduser()
    if p.suffix == ".json" and p.is_file():          # ekspor laporan
        d = json.loads(p.read_text())
        v = d.get("venue") or {}
        return dict(
            summary=d.get("summary") or {},
            zones=[{"code": z["code"], "visits": z["visits"],
                    **z.get("rect", {})} for z in (d.get("zones") or [])],
            occupancy=d.get("occupancy") or [],
            stops=[{"label": sp.get("name"), "dwellSeconds": sp.get("dwellSeconds")}
                   for sp in (d.get("stopPoints") or [])],
            tanpa_posisi=True,
            n_kamera=None,
            durasi=(d.get("window") or {}).get("durationSec") or 0,
            lebar=v.get("widthM", 10), tinggi=v.get("heightM", 7.5),
        )

    folder = KELUARAN / sumber                        # satu lari
    sub = sorted(x for x in folder.iterdir() if (x / "hasil.json").exists())
    d = json.loads((sub[0] / "hasil.json").read_text())
    src = d["sumber"]
    return dict(
        summary=d["summary"], zones=d.get("zones") or [],
        occupancy=d.get("occupancy") or [], stops=d.get("stops") or [],
        tanpa_posisi=False, n_kamera=len(sub),
        durasi=src["frame_diproses"] / max(src["fps_sumber"], 1),
        lebar=10, tinggi=7.5,
    )


def bagian_pembanding(utama: str, lain: list[str]) -> list[str]:
    """Ringkasan rekaman lain, plus perbandingan yang sudah dihitung Python.

    Yang membuat bagian ini berbahaya kalau ceroboh: dua rekaman bisa berasal
    dari POTONGAN VIDEO yang berbeda panjang. 47 orang dalam 2 menit dan 35
    orang dalam 6 menit bukan "yang pertama lebih ramai" — yang pertama justru
    jauh lebih padat. Karena itu yang dibandingkan adalah orang PER MENIT, dan
    durasinya selalu ikut disebut.
    """
    b = ["=== REKAMAN LAIN UNTUK DIBANDINGKAN ==="]
    baris = []
    for r in [utama] + lain:
        try:
            d = muat(r)
        except (OSError, KeyError, json.JSONDecodeError):
            b.append(f"  {r}: tidak bisa dibaca, abaikan.")
            continue
        s = d["summary"]
        menit = max(d["durasi"] / 60, 1e-6)
        laju = s["totalVisitors"] / menit
        baris.append((r, s["totalVisitors"], d["durasi"], laju,
                      s["avgDwellSeconds"]))
        b.append(f"  {r}: {s['totalVisitors']} orang dalam {d['durasi']:.0f} "
                 f"detik ({laju:.1f} orang/menit), dwell {s['avgDwellSeconds']} detik"
                 + ("   <- rekaman yang sedang dibahas" if r == utama else ""))

    if len(baris) > 1:
        ini = baris[0]
        b.append("")
        b.append("  Perbandingan (sudah dihitung, percayai ini):")
        for r, orang, durasi, laju, dwell in baris[1:]:
            beda = laju - ini[3]
            arah = ("lebih padat" if beda < -0.05 * ini[3] else
                    "lebih lengang" if beda > 0.05 * ini[3] else "sama padat")
            b.append(f"    dibanding {r}: rekaman ini {arah} "
                     f"({ini[3]:.1f} vs {laju:.1f} orang per menit).")
        b.append("    JANGAN membandingkan jumlah orang mentah — panjang "
                 "rekamannya berbeda. Pakai orang per menit.")
        b.append("    Ini rekaman yang berbeda, BUKAN hari yang berbeda. Jangan "
                 "sebut 'kemarin' atau 'hari ini' kecuali DATA menyebutnya.")
    b.append("")
    return b


def susun_konteks(run_id: str, pembanding: list[str] | None = None) -> str:
    d = muat(run_id)
    peta = peta_perabot(run_id)
    s = d["summary"]
    durasi = d["durasi"]

    kamera = (f"{d['n_kamera']} kamera dari sudut berbeda"
              if d["n_kamera"] else "kamera CCTV")
    b = ["=== FAKTA DASAR ==="]
    b.append(f"Ruangan pujasera {d['lebar']:g} x {d['tinggi']:g} meter, direkam "
             f"{kamera}, selama {durasi:.0f} detik.")
    b.append(f"Orang terdeteksi: sekitar {s['totalVisitors']} "
             f"(perkiraan — deteksi tidak menangkap semua orang).")
    # Ditulis sekalian dalam menit: ditanya "berapa menit", model menjawab
    # "49 detik" apa adanya dan pertanyaannya tidak benar-benar terjawab.
    dwell = s["avgDwellSeconds"]
    menitnya = ("kurang dari 1 menit" if dwell < 60
                else f"sekitar {dwell / 60:.1f} menit")
    b.append(f"Rata-rata satu orang BERADA DI RUANGAN: {dwell} detik "
             f"({menitnya}). Ini lama berada di ruangan, bukan lama duduk — "
             f"kita tidak bisa membedakan duduk dan berdiri.")
    b.append("")

    # ---- isi ruangan ----
    #
    # Daftar perabot ditulis SEBAGAI FAKTA TERSENDIRI, lepas dari ada tidaknya
    # titik henti. Sebelumnya keterangan ini cuma ikut menempel pada tempat yang
    # punya titik henti, jadi pertanyaan "cuci piring di mana" dijawab "tidak
    # tersedia" — padahal jawabannya ada di peta ruangan, cuma tidak pernah
    # sampai ke model karena konter kebetulan tidak punya titik henti.
    if not d["tanpa_posisi"]:
        b.append("=== ISI RUANGAN (denah, bukan hasil deteksi) ===")
        for nama, *_, jenis in peta:
            b.append(f"  {nama} — {KETERANGAN_JENIS[jenis]}")
        b.append("  Selebihnya lantai kosong tempat orang berjalan.")
        b.append("  Ini letak perabot, BUKAN hasil pengukuran. Kalau ditanya "
                 "apakah ada mesin kopi atau tempat cuci piring, jawab dari "
                 "daftar ini — tapi kita TIDAK mengukur aktivitas di sana.")
        b.append("")

    # ---- tempat orang berhenti, sudah diberi nama ----
    sah = []
    b.append("=== TEMPAT ORANG BERHENTI LAMA ===")
    b.append("Angka = TOTAL waktu-orang (semua orang dijumlahkan), BUKAN lama "
             "satu orang duduk.")
    for p in d["stops"]:
        detik = int(round(p["dwellSeconds"]))
        if d["tanpa_posisi"]:
            # Ekspor laporan tidak menyimpan koordinat, jadi titik ini TIDAK
            # BISA dinamai. Menyebutnya "meja panjang tengah" di sini akan jadi
            # tebakan yang terdengar seperti fakta.
            nama = p.get("label") or "titik tanpa nama"
            b.append(f"  {nama} (posisinya tidak tercatat): {detik} detik-orang")
            # Bentuknya harus tetap 4 unsur seperti cabang satunya; koordinat
            # diisi None karena ekspor memang tidak menyimpannya.
            sah.append((nama, detik, None, None))
            continue
        nama = nama_tempat(p["x"] * d["lebar"], p["y"] * d["tinggi"], peta)
        # Titik di luar ruangan dibuang, tidak ikut ditulis. Waktu masih
        # dicantumkan dengan keterangan "abaikan", model malah menyebutnya dalam
        # jawaban ("dua titik di luar ruangan tidak cocok") — kekurangan
        # kalibrasi kita jadi terdengar seperti saran tempat duduk.
        if "LUAR RUANGAN" in nama:
            continue
        # Titik sekecil ini bukan "tempat orang berhenti lama" — 3 detik-orang
        # dari total 900 adalah satu orang lewat sekali. Mencantumkannya membuat
        # daftar berisi tempat yang tidak layak disarankan ke siapa pun.
        if detik < MIN_DETIK_ORANG:
            continue
        sah.append((nama, detik, p["x"] * d["lebar"], p["y"] * d["tinggi"]))

    # Nama yang muncul lebih dari sekali diberi patokan arah — tapi HANYA yang
    # bentrok. Menambahkan "sisi tengah dekat konter" ke semua nama membuat
    # jawaban chatbot bertele-tele padahal tidak ada yang perlu dibedakan.
    berapa = {}
    for n, *_ in sah:
        berapa[n] = berapa.get(n, 0) + 1
    sah = [((bedakan(n, x, y) if berapa[n] > 1 and x is not None else n), t)
           for n, t, x, y in sah]
    if not d["tanpa_posisi"]:
        for n, t in sah:
            b.append(f"  {n}: {t} detik-orang "
                     f"[{KETERANGAN_JENIS[jenis_tempat(n, peta)]}]")
    if d["tanpa_posisi"]:
        b.append("PENTING: nama tempat ini cuma nomor urut. Kamu TIDAK TAHU "
                 "meja mana yang dimaksud — jangan menebak nama perabot.")
    else:
        # Tempat yang TIDAK punya titik henti disebut juga. Waktu namanya tidak
        # muncul sama sekali, model mengisi kekosongan itu sendiri: ditanya soal
        # meja panjang kanan, dia menjawab "termasuk zona D dan F" — keanggotaan
        # yang tidak ada di mana pun. Menyebut ketiadaannya lebih aman daripada
        # membiarkannya kosong.
        disebut = {n.split(" (")[0] for n, _ in sah}
        hilang = [n for n, *_ in peta if n not in disebut]
        if hilang:
            b.append("Tempat berikut TIDAK punya titik henti tercatat: "
                     + ", ".join(hilang) + ".")
            b.append("Itu BISA berarti sepi, bisa juga berarti tidak tertangkap "
                     "kamera dengan baik. Kalau ditanya soal tempat ini, katakan "
                     "datanya tidak ada — jangan menyimpulkan sepi, dan jangan "
                     "mengaitkannya dengan zona mana pun.")
    b.append("")

    # ---- zona A-F ----
    #
    # Dulu bagian ini tidak ada, dan ketika ditanya "zona A itu apa" model
    # menjawab "Zona A (meja panjang tengah)" — pemetaan yang tidak pernah ada
    # di mana pun. Fakta yang hilang tidak membuat model diam; dia mengarang.
    zones = d["zones"]
    b.append("=== ZONA A-F ===")
    if zones:
        b.append("Zona adalah KISI 3x2 yang membagi ruangan rata, BUKAN "
                 "perabot. Satu zona bisa menutupi setengah meja plus lantai "
                 "kosong, jadi JANGAN menyamakan zona dengan nama meja.")
        # Angka contohnya diambil dari data ini sendiri. Waktu masih ditulis
        # mati ("4513"), konteks untuk rekaman lain memuat angka yang tidak
        # ada di daftarnya — persis jenis ketidakcocokan yang bikin model
        # mengarang.
        tertinggi = max(z["visits"] for z in zones)
        b.append("Angka di bawah adalah jumlah SAMPEL (titik orang per frame), "
                 f"BUKAN jumlah orang. Zona dengan {tertinggi} sampel TIDAK "
                 f"berarti {tertinggi} orang — pengunjungnya cuma "
                 f"{s['totalVisitors']}. Sebutkan sebagai 'paling sering "
                 "dilewati', jangan pernah sebagai jumlah orang.")
        # Koordinat pusat SENGAJA tidak ditulis. Waktu masih dicantumkan
        # ("Zona A: sekitar (5.0m, 5.6m)"), model menyambungkannya ke peta
        # furnitur dan menjawab "Zona A berada di area meja panjang tengah" —
        # padahal satu zona seluas 3,3 x 3,8 m menutupi jauh lebih dari satu
        # meja. Angka yang terlalu presisi mengundang kesimpulan yang tidak
        # ditanggung datanya, jadi posisinya dinyatakan kasar saja.
        lz, tz = d["lebar"] / 3, d["tinggi"] / 2
        b.append(f"Tiap zona berukuran sekitar {lz:.1f} x {tz:.1f} meter — "
                 f"seperenam ruangan, jauh lebih luas dari satu meja.")
        for z in zones:
            kolom = ["sepertiga kiri", "sepertiga tengah",
                     "sepertiga kanan"][min(int(z["x"] * 3 + 0.5), 2)]
            baris = "bagian atas" if z["y"] < 0.5 else "bagian bawah"
            b.append(f"  Zona {z['code']}: {kolom} ruangan, {baris} — "
                     f"{z['visits']} sampel")
    else:
        b.append("Tidak ada data zona untuk rekaman ini.")
    b.append("")

    # ---- kapan ramai ----
    #
    # Sebelumnya bagian ini tidak ada sama sekali, dan pertanyaan "kapan ramai"
    # dijawab dengan nama tempat — model menjawab pertanyaan yang paling mirip
    # dengan data yang dia punya.
    occ = d["occupancy"]
    b.append("=== KERAMAIAN PER MENIT ===")
    if len(occ) < 3:
        # Rekaman 113 detik cuma punya dua titik. Menyebut salah satunya
        # "jam tersibuk" akan terdengar seperti pola harian, padahal beda dua
        # menit dalam satu rekaman pendek itu kebetulan.
        b.append(f"  Rekaman ini cuma {len(occ)} menit — TERLALU PENDEK untuk "
                 f"menyimpulkan kapan ramai atau kapan sepi. Kalau ditanya soal "
                 f"waktu ramai, jawab bahwa rekamannya terlalu pendek.")
    else:
        for o in occ:
            b.append(f"  menit ke-{o['minute']}: {o['count']} orang")
    b.append("  Menit dihitung dari awal rekaman, bukan jam dinding — kita tidak "
             "tahu pukul berapa rekaman ini dibuat.")
    b.append("")

    # ---- KESIMPULAN: dihitung Python, bukan oleh model ----
    b.append("=== KESIMPULAN (sudah dihitung, percayai ini) ===")
    if len(occ) >= 3:
        ramai = max(occ, key=lambda o: o["count"])
        sepi = min(occ, key=lambda o: o["count"])
        selisih = ramai["count"] - sepi["count"]
        # "Menit ke-2 paling ramai (16 orang)" terdengar seperti temuan, padahal
        # menit tersepinya 14. Selisih sekecil itu di bawah ketelitian deteksi
        # kita — menyebutnya puncak berarti melaporkan derau sebagai pola.
        if selisih <= 3 or selisih < 0.2 * max(ramai["count"], 1):
            b.append(f"  Keramaian RATA sepanjang rekaman: paling sepi "
                     f"{sepi['count']} orang, paling ramai {ramai['count']} "
                     f"orang. Selisih sekecil ini masih dalam ketelitian "
                     f"deteksi, jadi TIDAK ADA menit yang benar-benar menonjol. "
                     f"Kalau ditanya kapan paling ramai, katakan keramaiannya "
                     f"rata saja — jangan menyebut satu menit sebagai puncak.")
        else:
            b.append(f"  Paling ramai: menit ke-{ramai['minute']} "
                     f"({ramai['count']} orang).")
            b.append(f"  Paling sepi: menit ke-{sepi['minute']} "
                     f"({sepi['count']} orang).")
    if sah:
        urut = sorted(sah, key=lambda t: -t[1])
        b.append(f"  Tempat orang paling lama berhenti: {urut[0][0]} "
                 f"({urut[0][1]} detik-orang).")
        b.append("  Urutan: " + ", ".join(f"{n} ({v})" for n, v in urut))

        # Saran tempat duduk DISARING dulu ke jenis "duduk". Kalau daftarnya
        # diurutkan angka saja, jawaban untuk "di mana yang sepi" jatuh ke
        # lorong — paling sedikit orang berhenti di sana justru karena orang
        # cuma lewat.
        bisa_duduk = [(n, v) for n, v in urut if jenis_tempat(n, peta) == DUDUK]
        if bisa_duduk:
            b.append(f"  Paling cocok untuk berlama-lama (board game, belajar, "
                     f"rapat): {bisa_duduk[0][0]}"
                     + (f", lalu {bisa_duduk[1][0]}" if len(bisa_duduk) > 1 else "")
                     + ".")
            sepi_duduk = bisa_duduk[-1][0]
            b.append(f"  Tempat duduk paling sepi (untuk sendirian atau butuh "
                     f"tenang): {sepi_duduk}.")
        b.append("  Tempat berjenis 'lewat' dan 'layanan' TIDAK BOLEH disarankan "
                 "sebagai tempat duduk, sesepi apa pun angkanya.")
    b.append("")

    b.append("=== PERINGATAN YANG WAJIB DISAMPAIKAN ===")
    b.append(f"  Jumlah orang ({s['totalVisitors']}) adalah perkiraan KASAR dan "
             f"cenderung berlebih: pelacakan kadang memberi identitas baru saat "
             f"orang tertutup. Sebutkan sebagai kisaran, jangan sebagai angka pasti.")
    b.append(f"  'Puncak okupansi' ({s['peakOccupancy']}) di sini dihitung PER MENIT "
             f"— berapa orang lewat dalam satu menit, BUKAN berapa orang duduk "
             f"bersamaan dalam satu waktu. Jangan sebut sebagai 'bersamaan'.")
    b.append("  Angka tempat-berhenti TIDAK terpengaruh dua masalah di atas.")
    b.append("")

    if pembanding:
        b += bagian_pembanding(run_id, pembanding)

    b.append("=== YANG TIDAK DIUKUR ===")
    b.append("identitas orang, umur, jenis kelamin, apa yang dibeli, harga, menu, "
             "percakapan, cuaca, pendapatan, hari selain rekaman ini.")
    return "\n".join(b)


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
    estetik, cozy, santai, asyik. Yang kita punya cuma berapa lama orang
    berhenti di sana.

KALAU PEMAKAI MERAGUKAN ANGKAMU:
10. Periksa lagi ke DATA sebelum menjawab. Kalau angkamu memang ada di DATA,
    pertahankan dan jelaskan artinya. Kalau tidak ada, akui salah.
11. "detik-orang" adalah waktu SEMUA orang dijumlahkan, jadi wajar jauh lebih
    besar dari durasi rekaman. Itu bukan lama satu orang duduk.
12. DILARANG memakai emoji. DILARANG mengklaim datamu "akurat" atau "sudah
    jelas" — angka-angka ini perkiraan dari rekaman 113 detik.
13. Jangan minta maaf berlebihan dan jangan memuji pertanyaannya.
14. Zona (A-F) dan nama meja adalah DUA SISTEM BERBEDA. DILARANG mengatakan
    zona tertentu "adalah" atau "berada di" meja tertentu. Kalau ditanya zona
    itu meja apa, jawab bahwa zona cuma membagi ruangan jadi kisi dan tidak
    mengikuti perabot.
15. DILARANG menyarankan zona sebagai tempat ("zona A bisa jadi pilihan").
    Zona itu kotak di peta, bukan tempat yang bisa ditempati orang. Kalau
    menyarankan tempat, sebut nama perabotnya.
16. Pertanyaan ANDAI-ANDAI ("kalau layoutnya diganti", "kalau mejanya
    ditambah") paling gampang memancing karangan. Jawab HANYA dengan fakta
    terukur — tempat mana yang paling sering dan paling jarang dipakai — lalu
    katakan bahwa selebihnya di luar jangkauan data. DILARANG mengarang alasan
    soal pencahayaan, sirkulasi udara, estetika, atau kenyamanan.
"""

def bersihkan(teks: str) -> str:
    """Buang sisa Markdown dan label yang tetap lolos dari aturan.

    Instruksi "jangan pakai **" ditaati sebagian besar waktu, bukan selalu —
    dan satu jawaban bertabur bintang sudah cukup membuat tampilannya terlihat
    rusak. Yang bisa dipastikan kode, jangan diserahkan ke model.
    """
    teks = teks.split("</think>")[-1]
    teks = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", teks)
    teks = re.sub(r"(?m)^\s*[-*•]\s+", "", teks)
    teks = re.sub(r"(?m)^\s*\d+[.)]\s+", "", teks)
    teks = re.sub(r"(?m)^\s*(Kesimpulan|Peringatan|Catatan|Jawaban)\s*:\s*", "", teks)
    # Emoji dibuang di sini, bukan cuma dilarang di prompt. Larangannya ditaati
    # hampir selalu — dan "hampir" berarti satu jawaban dari dua puluh tetap
    # keluar dengan senyum di ujung laporan analisis.
    teks = re.sub("[\U0001F300-\U0001FAFF\U00002600-\U000027BF️]", "", teks)
    teks = re.sub(r" {2,}", " ", teks).replace(" .", ".").replace(" ,", ",")
    teks = re.sub(r"\n{2,}", "\n", teks)
    return teks.strip()


def tanya(pertanyaan: str, model: str, konteks: str, riwayat=None) -> str:
    """`riwayat`: [{"peran": "orang"|"bot", "teks": ...}] — giliran sebelumnya.

    Tanpa ini tiap pertanyaan berdiri sendiri, dan pertanyaan susulan seperti
    "kok lama banget 588 detik?" dijawab tanpa tahu 588 itu dari mana — model
    menyangkal angkanya sendiri.
    """
    pesan = [{"role": "system", "content": ATURAN + "\n\nDATA:\n" + konteks}]
    # Enam giliran terakhir saja: konteks DATA jauh lebih penting daripada
    # basa-basi lama, dan model 8B mulai kehilangan aturannya kalau percakapan
    # menumpuk.
    for g in (riwayat or [])[-6:]:
        pesan.append({"role": "user" if g.get("peran") == "orang" else "assistant",
                      "content": g.get("teks", "")})
    pesan.append({"role": "user", "content": pertanyaan})
    payload = {"model": model, "stream": False,
               "options": {"temperature": 0.2},
               "messages": pesan}
    # Mode berpikir qwen3 memakan separuh waktu jawab (25 detik jadi 13) untuk
    # penalaran yang tidak pernah ditampilkan ke pemakai. Dimatikan hanya kalau
    # ujian membuktikan jawabannya tetap benar — kecepatan tidak ada gunanya
    # kalau jawabannya salah.
    if not BERPIKIR:
        payload["think"] = False
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return bersihkan(json.load(r)["message"]["content"])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    q = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "qwen3:8b"
    run = sys.argv[3] if len(sys.argv) > 3 else "run-shafa-sambung"
    K = susun_konteks(run)
    print("=" * 66); print(K); print("=" * 66)
    print(f"[{model}] {q}\n")
    print(tanya(q, model, K))
