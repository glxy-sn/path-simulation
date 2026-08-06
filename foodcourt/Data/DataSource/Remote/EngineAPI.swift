//
//  EngineAPI.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation

struct PointDTO: Codable { let x: Double; let y: Double }

struct VenueDTO: Codable {
    let widthM: Double
    let heightM: Double
    let name: String
    let type: String
}

struct CameraDTO: Codable {
    let label: String
    let videoPath: String
    let imagePoints: [PointDTO]
    let planePoints: [PointDTO]
    let startSec: Double
    let durationSec: Double?
}

struct JobOptionsDTO: Codable { let renderVideos: Bool }

struct JobRequestDTO: Codable {
    let venue: VenueDTO
    let mode: String
    let cameras: [CameraDTO]
    let options: JobOptionsDTO
}

// MARK: Response DTO

struct CreateJobResponse: Codable { let jobId: String }

struct ProgressDTO: Codable {
    let jobId: String
    let status: String       // queued | running | done | error
    let stage: String
    let fraction: Double
    let error: String?
}

struct SummaryDTO: Codable {
    let totalVisitors: Int
    let avgDwellSeconds: Int
    let peakOccupancy: Int
    let captureRate: Double
}

struct RectDTO: Codable { let x: Double; let y: Double; let w: Double; let h: Double }
struct ZoneDTO: Codable {
    let code: String; let visits: Int; let share: Double; let rect: RectDTO
    /// Warna dipilih engine supaya satu zona tetap berwarna sama walau
    /// peringkatnya berubah setelah kotaknya digeser manual. Opsional —
    /// engine yang tidak mengirimnya membuat UI jatuh ke palet urutan.
    let colorHex: UInt?
}
struct StopDTO: Codable { let label: String; let x: Double; let y: Double; let dwellSeconds: Int }
struct OccDTO: Codable { let minute: Int; let count: Int }
struct OverlayDTO: Codable { let cam: String; let uri: String }

struct ArtifactsDTO: Codable {
    let heatmapImage: String?
    /// Satu frame CCTV, dipakai sebagai LATAR gambar jalur dan heatmap.
    /// Koordinat hasil ada di ruang gambar kamera, jadi frame ini menempel
    /// persis tanpa proyeksi — dan tanpanya jalur melayang di kotak kosong
    /// yang tidak dikenali siapa pun sebagai tempatnya sendiri.
    let frameLatar: String?
    let pathVideo: String?
    let overlayVideos: [OverlayDTO]
}

// MARK: Riwayat

/// Ringkasan satu lari tersimpan, untuk kartu di layar Riwayat.
struct RunDTO: Codable {
    let id: String
    let video: String
    let waktu: String
    let frameDiproses: Int
    let detik: Double
    let peakOccupancy: Int
    let totalVisitors: Int
    let ukuranByte: Int64
    let adaVideo: Bool
}

struct RunsResponse: Codable { let runs: [RunDTO] }

// MARK: Di luar kontrak inti
//
// Kontrak inti hanya memuat ringkasan, zona, okupansi, dan artefak. Pipeline
// Re-ID menghasilkan lebih dari itu, dan tiga di antaranya bukan hiasan:
//
//   grid + jejak  dipakai aplikasi untuk MENGHITUNG ULANG angka tiap zona
//                 ketika kotaknya digeser manual. Tanpa keduanya, zona yang
//                 disunting tidak punya angka sama sekali.
//   galat         menyatakan seberapa meleset totalVisitors dan avgDwell
//                 terhadap anotasi manusia DI VENUE INI. Tanpa ini, angka
//                 tampil seolah-olah pasti.
//
// Semuanya opsional, jadi engine yang belum mengirimkannya tetap terbaca.

struct BlobDTO: Codable { let x: Double; let y: Double; let intensity: Double; let radius: Double }
struct PathDTO: Codable { let points: [[Double]]; let hue: Double }
struct GridDTO: Codable { let w: Int; let h: Int; let total: Int; let sel: [Int] }

struct SumberDTO: Codable {
    let video: String
    let mulai_detik: Int
    let frame_diproses: Int
    /// Double, bukan Int. Sebagian rekaman melaporkan 20,013 fps — dengan Int
    /// seluruh respons gagal didekode tanpa pesan apa pun.
    let fps_sumber: Double
    /// Ukuran frame asli. Koordinat di hasil sudah dibagi lebar dan tinggi
    /// secara terpisah, jadi rasio ini diperlukan untuk menggambar jalur
    /// dengan bentuk yang benar.
    let lebar: Int?
    let tinggi: Int?
}

struct DiagnostikDTO: Codable {
    let id_unik_setelah_sambung: Int?
    let penyambungan: Int?
    let diukur_terhadap: String?
    let catatan: String?
}

struct ExtraDTO: Codable {
    let sumber: SumberDTO?
    let occupancySatuan: String?
    let blobs: [BlobDTO]?
    let paths: [PathDTO]?
    let grid: GridDTO?
    let jejak: [String: [[Double]]]?
    let jejakLangkah: Int?
    let totalVisitorsGalat: Double?
    let avgDwellGalat: Double?
    let galatSumber: String?
    let captureRateVenueIni: Bool?
    let diagnostik: DiagnostikDTO?
    let folder: String?
    /// Hal yang perlu dikatakan apa adanya ke pengguna: kamera kedua tidak
    /// dianalisis, kalibrasi belum dipakai, dan sebagainya.
    let catatan: [String]?
}

/// Hasil satu sudut kamera. Bentuknya sama dengan JobResultDTO tanpa daftar
/// kamera di dalamnya — tipe yang memuat dirinya sendiri tidak bisa didekode.
struct CameraResultDTO: Codable {
    let label: String?
    let summary: SummaryDTO
    let zones: [ZoneDTO]
    let stopPoints: [StopDTO]
    let occupancy: [OccDTO]
    let artifacts: ArtifactsDTO
    let extra: ExtraDTO?
}

/// Angka yang boleh dijumlahkan antar kamera.
///
/// Hanya okupansi. Total pengunjung sengaja TIDAK ada di sini: orang yang
/// berpindah antar sudut akan terhitung dua kali, dan menyatukannya butuh
/// Re-ID lintas kamera yang belum ada. Angka yang tersedia akan dipakai orang,
/// jadi yang tidak boleh dijumlahkan tidak dikirim sama sekali.
struct GabunganDTO: Codable {
    let peakOccupancy: Int?
    let occupancy: [OccDTO]?
    let satuan: String?
    let catatan: String?
}

struct JobResultDTO: Codable {
    let jobId: String
    let venue: VenueDTO
    let summary: SummaryDTO
    let zones: [ZoneDTO]
    let stopPoints: [StopDTO]
    let occupancy: [OccDTO]
    let artifacts: ArtifactsDTO
    let trajectories: String?
    let extra: ExtraDTO?
    /// Berisi tiap sudut kamera saat analisis memakai lebih dari satu kamera.
    let cameras: [CameraResultDTO]?
    let gabungan: GabunganDTO?
}

// MARK: API

struct EngineAPI {
    let http: HTTPClient

    func createJob(_ req: JobRequestDTO) async throws -> String {
        let r: CreateJobResponse = try await http.post("/jobs", body: req)
        return r.jobId
    }

    func progress(_ id: String) async throws -> ProgressDTO {
        try await http.get("/jobs/\(id)/progress")
    }

    func result(_ id: String) async throws -> JobResultDTO {
        try await http.get("/jobs/\(id)/result")
    }

    // MARK: riwayat
    //
    // Dibaca dari engine, bukan dari berkas langsung, karena engine yang tahu
    // di mana hasil disimpan — dan versi web nanti tidak punya akses ke disk
    // pengguna sama sekali.

    func runs() async throws -> [RunDTO] {
        let r: RunsResponse = try await http.get("/runs")
        return r.runs
    }

    func runResult(_ id: String) async throws -> JobResultDTO {
        try await http.get("/runs/\(id)/result")
    }

    @discardableResult
    func deleteRun(_ id: String) async throws -> [String: String] {
        try await http.post("/runs/\(id)/delete", body: [String: String]())
    }
}
