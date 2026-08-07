//
//  AnalysisSession.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation
import Observation
import CoreGraphics

struct SessionCamera: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var url: URL?
    var resolution: String = "—"
    var durationSec: Double = 0
    var imagePoints: [NormPoint] = []
    var planePoints: [NormPoint] = []
    var referenceFrameSeconds: Double = 0
    var framePixelSize: PixelSize?
    var calibration: CameraCalibration?

    var isCalibrated: Bool { calibration?.isValid == true }
}

/// Hasil yang sudah dipetakan ke model UI (siap dipakai layar Hasil).
struct AnalysisResult {
    var summary: VenueSummary
    var zones: [ZoneRank]
    var stops: [StopPoint]
    var occupancy: [OccupancyPoint]
    var heatmapURL: URL?
    /// Frame CCTV sebagai latar gambar jalur, heatmap, dan zona.
    var latarURL: URL?
    var pathVideoURL: URL?
    var overlayVideos: [(cam: String, url: URL)]

    // MARK: dari engine, di luar kontrak inti

    var blobs: [HeatBlob] = []
    var paths: [PathTrace] = []
    /// Petak kepadatan titik kaki + jejak per orang. Keduanya diperlukan untuk
    /// menghitung ulang angka zona saat kotaknya digeser manual.
    var grid: (w: Int, h: Int, total: Int, sel: [Int])?
    var jejak: [String: [CGPoint]] = [:]
    var jejakLangkah: Int = 20

    /// Sumbu grafik okupansi: "menit" untuk rekaman panjang, "detik" untuk
    /// potongan pendek. Salah label membuat 8 detik terbaca sebagai 8 menit.
    var occupancySatuan: String = "menit"
    var fpsSumber: Double = 0
    var frameDiproses: Int = 0
    var namaVideo: String = ""
    /// Rasio lebar:tinggi video asli. Koordinat hasil sudah dibagi lebar dan
    /// tinggi terpisah, jadi tanpa ini jalur digambar dengan bentuk yang
    /// mengikuti kotak gambarnya, bukan mengikuti gerak orangnya.
    var rasioVideo: Double = 16.0 / 9.0

    /// Seberapa meleset angkanya terhadap anotasi manusia DI VENUE INI.
    /// nil berarti venue ini belum pernah diukur — dan itu harus dikatakan,
    /// bukan ditambal dengan galat venue lain.
    var totalVisitorsGalat: Double?
    var avgDwellGalat: Double?
    var galatSumber: String?
    var captureRateVenueIni = false
    var diagnostik: String?
    var folder: URL?
    var catatan: [String] = []

    // MARK: proyeksi ke denah lantai

    /// Homografi piksel kamera -> meter di lantai, dari layar Kalibrasi.
    ///
    /// Kalau ada, keempat visualisasi berpindah sendiri ke tampilan denah:
    /// perspektif hilang, dan dua orang yang berjalan di lorong yang sama tapi
    /// beda jarak dari kamera akhirnya tergambar berimpit. Itu yang selama ini
    /// menghalangi pola muncul.
    ///
    /// Hanya sahih untuk titik DI LANTAI — dan itu sebabnya sejak awal yang
    /// dipakai titik kaki, bukan tengah badan.
    var homografi: Matrix3x3?
    /// Ukuran frame asli dalam piksel. Koordinat hasil ternormalkan 0–1, jadi
    /// harus dikembalikan ke piksel dulu sebelum dilewatkan homografi.
    var ukuranFramePx: PixelSize?
    /// Ukuran venue dalam meter — batas bidang gambar denah.
    var venueMeter: CGSize?

    var adaDenah: Bool { homografi != nil && ukuranFramePx != nil && venueMeter != nil }

    /// Titik hasil (0–1 terhadap frame) -> meter di lantai.
    func keLantai(_ p: CGPoint) -> CGPoint? {
        guard let H = homografi, let px = ukuranFramePx else { return nil }
        let titik = CalibrationPoint(x: p.x * px.width, y: p.y * px.height)
        guard let m = HomographySolver.transform(titik, with: H) else { return nil }
        return CGPoint(x: m.x, y: m.y)
    }

    // MARK: multi-kamera

    /// Nama sudut ini ("Kamera 1"). Kosong untuk analisis satu kamera.
    var label: String = ""
    /// Tiap sudut kamera, dianalisis terpisah. Kosong kalau cuma satu kamera.
    var perKamera: [AnalysisResult] = []
    /// Puncak okupansi seluruh sudut, dijumlahkan per satuan waktu.
    var puncakGabungan: Int?
    var okupansiGabungan: [OccupancyPoint] = []
    var catatanGabungan: String?

    // MARK: keterangan untuk kartu di layar Hasil

    private func keterangan(_ galat: Double?) -> String {
        guard let g = galat else {
            return "Galat belum diukur untuk video ini — angka ini mentah."
        }
        let arah = g >= 0 ? "berlebih" : "kurang"
        return "Terbaca \(arah) ~\(Int((abs(g) * 100).rounded()))% terhadap anotasi manusia"
            + (galatSumber.map { " (\($0))" } ?? "") + "." + peringatanDurasi
    }

    /// Galat itu diukur pada SATU segmen pendek. Memakainya untuk klip yang
    /// jauh lebih panjang adalah perpanjangan yang belum diuji — dan buktinya
    /// mengarah ke satu sisi: makin lama rekamannya, makin sering orang
    /// tertutup, makin sering track putus, dan tiap track yang putus
    /// melahirkan ID baru. Terukur pada rekaman yang sama: track berumur
    /// ≤3 detik naik dari 0% pada klip 45 detik menjadi 12% pada klip 3 menit,
    /// dan penyambungan ID dari 33 menjadi 148.
    ///
    /// Jadi untuk klip panjang, galat sebenarnya kemungkinan LEBIH BESAR
    /// daripada angka yang tertulis. Itu harus dikatakan, bukan dibiarkan
    /// tampak pasti.
    private var peringatanDurasi: String {
        let detik = fpsSumber > 0 ? Double(frameDiproses) / fpsSumber : 0
        guard detik > 120 else { return "" }
        return " Galat itu diukur pada satu segmen pendek; klip ini "
            + "\(Int((detik / 60).rounded())) menit, dan track lebih sering putus "
            + "pada klip panjang — galat sebenarnya kemungkinan lebih besar."
    }

    /// Penanda "ini hasil yang mana", supaya layar Hasil tahu kapan harus
    /// membaca ulang. Tanpa ini, analisis kedua menampilkan angka pertama.
    var jobIdentitas: String { "\(namaVideo)|\(frameDiproses)|\(folder?.path ?? "")" }

    // MARK: - Lama tinggal per area

    /// Berapa lama orang berada di dalam sebuah area.
    struct LamaTinggal {
        /// Banyaknya orang berbeda yang pernah masuk area ini.
        var orang: Int
        /// Jumlah waktu seluruh orang di dalamnya (orang-detik).
        var totalDetik: Double
        /// Rata-rata per orang — ini yang menjawab "berapa lama biasanya
        /// seseorang berhenti di sini".
        var rataDetik: Double
        /// Orang yang paling lama bertahan di area ini.
        var terlamaDetik: Double
    }

    /// Hitung lama tinggal di sebuah kotak, dari jejak titik kaki tiap orang.
    ///
    /// Sengaja dihitung DI APLIKASI, bukan di pipeline: kotak zona bisa
    /// digeser manual, dan angka yang dihitung di pipeline langsung basi
    /// begitu kotaknya diubah.
    ///
    /// Perhitungannya tidak mengenal jenis venue. "Berapa lama orang berada di
    /// dalam kotak ini" berlaku sama untuk kursi pantry, meja pujasera, atau
    /// antrian kasir minimarket — yang berbeda cuma letak kotaknya.
    ///
    /// Yang perlu diingat saat membacanya: jejak diambil setiap
    /// `jejakLangkah` frame, jadi satuan terkecil yang bisa terukur adalah
    /// `jejakLangkah / fps` detik (biasanya sekitar 1 detik). Dan karena track
    /// putus tiap kali orangnya tertutup meja atau orang lain, angka ini
    /// cenderung KURANG dari kenyataan — arah galat yang sama dengan dwell
    /// keseluruhan.
    func lamaTinggal(di kotak: CGRect) -> LamaTinggal {
        guard fpsSumber > 0, jejakLangkah > 0 else {
            return LamaTinggal(orang: 0, totalDetik: 0, rataDetik: 0, terlamaDetik: 0)
        }
        let perTitik = Double(jejakLangkah) / fpsSumber

        var durasi: [Double] = []
        for (_, titik) in jejak {
            let n = titik.reduce(into: 0) { hasil, p in
                if kotak.contains(p) { hasil += 1 }
            }
            if n > 0 { durasi.append(Double(n) * perTitik) }
        }
        guard !durasi.isEmpty else {
            return LamaTinggal(orang: 0, totalDetik: 0, rataDetik: 0, terlamaDetik: 0)
        }
        let total = durasi.reduce(0, +)
        return LamaTinggal(orang: durasi.count,
                           totalDetik: total,
                           rataDetik: total / Double(durasi.count),
                           terlamaDetik: durasi.max() ?? 0)
    }

    /// Hitung ulang angka sebuah kotak dari petak kepadatan.
    ///
    /// Dipakai saat zona digeser manual. Petak 120×68 dikirim justru untuk ini:
    /// tanpa petak, kotak yang dipindahkan tidak punya angka apa pun, karena
    /// jumlah pengamatan titik kaki hanya diketahui pipeline.
    ///
    /// Hasilnya perkiraan sebatas ukuran petak — satu petak ≈ 0,8% lebar
    /// gambar, jadi geseran yang lebih halus dari itu tidak mengubah angka.
    func kepadatan(di kotak: CGRect) -> (pengamatan: Int, porsi: Double) {
        guard let g = grid, g.w > 0, g.h > 0, g.total > 0 else { return (0, 0) }

        // Sel dihitung kalau PUSATNYA di dalam kotak.
        //
        // Cara sebelumnya memasukkan setiap sel yang bersentuhan dengan kotak,
        // termasuk yang cuma tersenggol pinggirnya — dan sel padat tepat di
        // luar batas ikut terhitung penuh. Terukur pada satu zona: 999 versus
        // 559 yang sebenarnya, meleset 79%. Dengan pusat sel, rata-rata galat
        // terhadap angka pipeline turun dari 16% ke 1%.
        let x0 = max(0, Int((kotak.minX * Double(g.w) - 0.5).rounded(.up)))
        let x1 = min(g.w - 1, Int((kotak.maxX * Double(g.w) - 0.5).rounded(.down)))
        let y0 = max(0, Int((kotak.minY * Double(g.h) - 0.5).rounded(.up)))
        let y1 = min(g.h - 1, Int((kotak.maxY * Double(g.h) - 0.5).rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return (0, 0) }

        var jumlah = 0
        for y in y0...y1 {
            let baris = y * g.w
            for x in x0...x1 { jumlah += g.sel[baris + x] }
        }
        return (jumlah, Double(jumlah) / Double(g.total))
    }

    /// Area diurutkan dari yang paling lama ditinggali per orang — inilah
    /// "stop point": tempat orang benar-benar berhenti, bukan sekadar lewat.
    ///
    /// Diurutkan berdasarkan RATA-RATA per orang, bukan totalnya. Area yang
    /// dilewati banyak orang sebentar-sebentar akan menang kalau totalnya yang
    /// dipakai, padahal tidak ada yang berhenti di sana.
    var stopPoints: [StopPoint] {
        zones.map { zona -> (StopPoint, Double) in
            let l = lamaTinggal(di: zona.rect)
            return (StopPoint(name: "\(zona.name) · \(l.orang) orang",
                              dwellSeconds: Int(l.rataDetik.rounded())), l.rataDetik)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var visitorsKeterangan: String { keterangan(totalVisitorsGalat) }
    var dwellKeterangan: String { keterangan(avgDwellGalat) }
    var captureKeterangan: String {
        captureRateVenueIni
            ? "Recall detektor diukur di venue ini."
            : "Recall dipinjam dari venue lain — belum diukur untuk video ini."
    }
}

@Observable
final class AnalysisSession {
    // Venue
    var venueName = ""
    var venueType: VenueType = .pujasera
    var widthM = "10"
    var heightM = "7.5"
    var mode: AnalysisMode = .lengkap

    // Kamera + kalibrasi
    var cameras: [SessionCamera] = []
    var floorPlanURL: URL?
    var floorPlanName: String?
    var floorPlanPixelSize: PixelSize?
    /// Pilihan sumber yang aktif. Berkas denah tetap disimpan saat pengguna beralih ke canvas.
    var usesScaledCanvas = true

    // Trim global
    var trimStartSec: Double = 0
    var trimEndSec: Double = 600

    // Status job
    var jobId: String?
    var stage: String = ""
    var progress: Double = 0
    var isProcessing = false
    var errorMessage: String?
    var result: AnalysisResult?

    // Turunan
    var venueWidthM: Double { Double(widthM) ?? 0 }
    var venueHeightM: Double { Double(heightM) ?? 0 }
    var timelineMax: Double { cameras.compactMap { $0.durationSec > 0 ? $0.durationSec : nil }.min() ?? 0 }
    var previewURL: URL? { cameras.first { $0.url != nil }?.url }
    var allCalibrated: Bool { !cameras.isEmpty && cameras.allSatisfy { $0.isCalibrated } }

    var calibrationFloorSize: PixelSize {
        if !usesScaledCanvas, let floorPlanPixelSize, floorPlanPixelSize.isValid { return floorPlanPixelSize }
        return PixelSize(width: 1000, height: 1000)
    }

    func normalizeTrim() {
        let m = timelineMax
        guard m > 0 else { trimStartSec = 0; trimEndSec = 0; return }
        trimStartSec = min(max(0, trimStartSec), m)
        if trimEndSec <= trimStartSec || trimEndSec > m {
            trimEndSec = min(m, trimStartSec + 600)
        }
    }

    func reset() {
        cameras = []
        floorPlanURL = nil; floorPlanName = nil; floorPlanPixelSize = nil; usesScaledCanvas = true
        jobId = nil; stage = ""; progress = 0
        isProcessing = false; errorMessage = nil; result = nil
    }
}
