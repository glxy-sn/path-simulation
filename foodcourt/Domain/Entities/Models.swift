//
//  Models.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import Foundation
import CoreGraphics

// MARK: - Import

struct CameraClip: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var fileName: String
    var resolution: String
    var durationSec: Double
    var url: URL? = nil
    var duration: String { timecode(durationSec) }
}

/// Format detik -> "H:MM:SS" atau "M:SS".
func timecode(_ sec: Double) -> String {
    let x = max(0, Int(sec.rounded()))
    let h = x / 3600, m = (x % 3600) / 60, s = x % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

extension CameraClip {
    static let samples: [CameraClip] = [
        .init(label: "Pintu Masuk", fileName: "cam_entrance.mp4", resolution: "1920×1080", durationSec: 7200),
        .init(label: "Area Tengah", fileName: "cam_center.mp4",   resolution: "1920×1080", durationSec: 7200),
        .init(label: "Kasir",       fileName: "cam_cashier.mp4",  resolution: "1280×720",  durationSec: 5400)
    ]
}

enum VenueType: String, CaseIterable, Identifiable {
    case pujasera = "Pujasera / Food Court"
    case minimarket = "Minimarket"
    case mall = "Mall"
    case other = "Lainnya"
    var id: String { rawValue }
}

enum AnalysisMode: String, CaseIterable, Identifiable {
    case lengkap = "Mode Lengkap"
    case cepat = "Mode Cepat"
    var id: String { rawValue }
    var detail: String {
        switch self {
        // Yang dijanjikan di sini harus persis yang dikerjakan. Homografi
        // sekarang benar-benar dipakai — Jalur, Heatmap, dan Zona berpindah
        // sendiri ke denah tampak atas begitu kalibrasinya sahih. ID lintas
        // kamera masih BELUM, dan karena itu tetap disebut belum ada:
        // terukur cuma ~20% pasangan yang benar, tidak layak dipakai.
        case .lengkap: return "Gambar 4 titik lantai, lalu Jalur, Heatmap, dan Zona "
            + "ditampilkan sebagai denah tampak atas — perspektif hilang dan jarak "
            + "di gambar jadi jarak sebenarnya, dalam meter. ID lintas kamera belum ada."
        case .cepat:   return "Langsung proses, tanpa kalibrasi. Angkanya sama, "
            + "tapi gambarnya tetap dari sudut kamera: orang yang jauh tampak "
            + "berpindah lebih sedikit daripada yang dekat walau jaraknya sama."
        }
    }
}

// MARK: - Kalibrasi

enum PlaneSource: String, CaseIterable, Identifiable {
    case canvas = "Canvas berskala"
    case floorplan = "Upload floor plan"
    var id: String { rawValue }
}

struct NormPoint: Identifiable, Hashable {
    let id = UUID()
    var x: Double
    var y: Double
}

// MARK: - Processing

enum StageState: Hashable { case pending, active, done }

struct ProcessingStage: Identifiable {
    let id = UUID()
    let name: String
    let systemImage: String
    var state: StageState = .pending
}

extension ProcessingStage {
    static let pipeline: [ProcessingStage] = [
        // Nama menyusul pipeline yang benar-benar dijalankan. Sebelumnya
        // tertulis "YOLO11x" (detektornya YOLO11s fine-tune) dan "Fusion
        // multi-kamera" (tidak ada fusion — yang terjadi penyambungan ID
        // di dalam satu kamera).
        .init(name: "Deteksi orang (YOLO11s fine-tune)", systemImage: "person.crop.rectangle"),
        .init(name: "Tracking (BoT-SORT + OSNet Re-ID)", systemImage: "point.topleft.down.to.point.bottomright.curvepath"),
        .init(name: "Penyambungan ID (1 kamera)",        systemImage: "link"),
        .init(name: "Analitik (heatmap, zona, path)",    systemImage: "chart.dots.scatter")
    ]
}

// MARK: - Hasil

struct VenueSummary {
    var totalVisitors: Int
    var avgDwellSeconds: Int
    var peakOccupancy: Int
    var captureRate: Double

    var avgDwellText: String {
        let m = avgDwellSeconds / 60, s = avgDwellSeconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
    var captureRateText: String { "\(Int((captureRate * 100).rounded()))%" }
}

struct ZoneRank: Identifiable {
    let id = UUID()
    let rank: Int
    let code: String        // "A", "B", "C", ...
    let visits: Int
    let share: Double
    let rect: CGRect        // posisi zona di bidang lantai (ternormalisasi 0–1)
    let colorHex: UInt      // warna zona (dipakai peta + list ranking)
    var name: String { "Zona \(code)" }
}

struct StopPoint: Identifiable {
    let id = UUID()
    let name: String
    let dwellSeconds: Int
    var dwellText: String {
        let m = dwellSeconds / 60, s = dwellSeconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

struct OccupancyPoint: Identifiable {
    let id = UUID()
    let minute: Int
    let count: Int
}

struct HeatBlob: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let intensity: Double
    let radius: Double
}

/// Jalur pergerakan (untuk path simulation) — titik ternormalisasi 0–1.
struct PathTrace: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    let hue: Double
}

enum SampleResult {
    static let summary = VenueSummary(
        totalVisitors: 143,
        avgDwellSeconds: 87,
        peakOccupancy: 12,
        captureRate: 0.34
    )

    static let zones: [ZoneRank] = [
        .init(rank: 1, code: "A", visits: 118, share: 0.82,
              rect: CGRect(x: 0.35, y: 0.38, width: 0.30, height: 0.24), colorHex: 0x5457D6),
        .init(rank: 2, code: "B", visits: 96,  share: 0.67,
              rect: CGRect(x: 0.68, y: 0.55, width: 0.24, height: 0.22), colorHex: 0xF59E0B),
        .init(rank: 3, code: "C", visits: 74,  share: 0.52,
              rect: CGRect(x: 0.10, y: 0.55, width: 0.22, height: 0.24), colorHex: 0x22C55E),
        .init(rank: 4, code: "D", visits: 61,  share: 0.43,
              rect: CGRect(x: 0.30, y: 0.08, width: 0.28, height: 0.16), colorHex: 0xEC4899),
        .init(rank: 5, code: "E", visits: 29,  share: 0.20,
              rect: CGRect(x: 0.72, y: 0.12, width: 0.20, height: 0.18), colorHex: 0x14B8A6)
    ]

    static let stops: [StopPoint] = [
        .init(name: "Meja promo tengah", dwellSeconds: 240),
        .init(name: "Antrian kasir",     dwellSeconds: 186),
        .init(name: "Rak minuman",       dwellSeconds: 132)
    ]

    static let occupancy: [OccupancyPoint] = (0..<24).map {
        let base = 6.0 + 5.0 * sin(Double($0) / 3.2)
        return OccupancyPoint(minute: $0 * 5, count: max(0, Int(base.rounded())))
    }

    static let blobs: [HeatBlob] = [
        .init(x: 0.50, y: 0.45, intensity: 1.0,  radius: 0.22),
        .init(x: 0.72, y: 0.60, intensity: 0.8,  radius: 0.16),
        .init(x: 0.30, y: 0.62, intensity: 0.6,  radius: 0.15),
        .init(x: 0.20, y: 0.30, intensity: 0.45, radius: 0.12),
        .init(x: 0.82, y: 0.28, intensity: 0.35, radius: 0.10)
    ]

    static let paths: [PathTrace] = [
        .init(points: [CGPoint(x: 0.08, y: 0.20), CGPoint(x: 0.30, y: 0.35),
                       CGPoint(x: 0.52, y: 0.30), CGPoint(x: 0.74, y: 0.48),
                       CGPoint(x: 0.90, y: 0.44)], hue: 0.58),
        .init(points: [CGPoint(x: 0.12, y: 0.75), CGPoint(x: 0.34, y: 0.60),
                       CGPoint(x: 0.50, y: 0.66), CGPoint(x: 0.68, y: 0.52),
                       CGPoint(x: 0.86, y: 0.62)], hue: 0.03),
        .init(points: [CGPoint(x: 0.20, y: 0.50), CGPoint(x: 0.40, y: 0.46),
                       CGPoint(x: 0.58, y: 0.54), CGPoint(x: 0.80, y: 0.36)], hue: 0.33)
    ]
}

// MARK: - Riwayat

struct HistoryEntry: Identifiable {
    let id = UUID()
    let venue: String
    let type: String
    let date: Date
    let cameraCount: Int
    let visitors: Int
    let avgDwellSeconds: Int
    let mode: String

    /// Penanda lari di engine (`run-…`). nil untuk entri contoh — entri tanpa
    /// ini tidak bisa dibuka atau dihapus, karena tidak ada apa pun di disk.
    var runId: String? = nil
    /// Diisi untuk lari sungguhan; kartu menampilkan ini alih-alih jumlah
    /// pengunjung, karena puncak okupansi tidak punya galat sebesar itu.
    var peakOccupancy: Int? = nil
    var durationText: String? = nil
    /// Besar folder di disk. Rekaman beranotasi 2–13 MB per lari menumpuk
    /// cepat, dan pemiliknya berhak tahu sebelum memutuskan menghapus.
    var ukuranByte: Int64 = 0

    var avgDwellText: String {
        let m = avgDwellSeconds / 60, s = avgDwellSeconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
    var dateText: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension HistoryEntry {
    static let samples: [HistoryEntry] = [
        .init(venue: "Pujasera Kampus", type: "Pujasera / Food Court",
              date: Date().addingTimeInterval(-3600 * 5),
              cameraCount: 3, visitors: 143, avgDwellSeconds: 87, mode: "Mode Lengkap"),
        .init(venue: "Minimarket Blok C", type: "Minimarket",
              date: Date().addingTimeInterval(-3600 * 30),
              cameraCount: 2, visitors: 89, avgDwellSeconds: 64, mode: "Mode Lengkap"),
        .init(venue: "Atrium Mall Timur", type: "Mall",
              date: Date().addingTimeInterval(-3600 * 74),
              cameraCount: 4, visitors: 512, avgDwellSeconds: 132, mode: "Mode Cepat"),
        .init(venue: "Food Court Lt. 3", type: "Pujasera / Food Court",
              date: Date().addingTimeInterval(-3600 * 120),
              cameraCount: 3, visitors: 201, avgDwellSeconds: 96, mode: "Mode Lengkap")
    ]
}
