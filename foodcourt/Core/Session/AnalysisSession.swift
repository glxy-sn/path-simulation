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
    /// Waktu sumber video = waktu global + offset. Positif berarti membaca frame lebih akhir.
    var timeOffsetSec: Double = 0
    var framePixelSize: PixelSize?
    var calibration: CameraCalibration?
    var isCalibrated: Bool { calibration?.isValid == true }
}

struct TrimCameraPreview: Identifiable, Hashable {
    let id: UUID
    let label: String
    let url: URL
    let offsetSec: Double
}

struct IdentityQualitySummary {
    var globalIDs: Int
    var localStitches: Int
    var overlapMerges: Int
    var handoverMerges: Int
    var unmatchedTracklets: Int
    var filteredTracklets: Int
    var highConfidence: Int
    var mediumConfidence: Int
    var lowConfidence: Int
    var singleCamera: Int
    var calibrationWarnings: [String]
}

/// Hasil yang sudah dipetakan ke model UI (siap dipakai layar Hasil).
struct AnalysisResult {
    var summary: VenueSummary
    var zones: [ZoneRank]
    var stops: [StopPoint]
    var occupancy: [OccupancyPoint]
    var heatmapURL: URL?
    var pathVideoURL: URL?
    var combinedVideoURL: URL?
    var overlayVideos: [(cam: String, url: URL)]
    var blobs: [HeatBlob]
    var paths: [PathTrace]
    var identityQuality: IdentityQualitySummary?
    var fusionDiagnosticsURL: URL?
    var observations: [TrackObservation] = []
}

/// Zona buatan pengguna (bisa digambar/geser/resize/rename di layar Hasil).
struct CustomZone: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var rect: CGRect          // ternormalisasi 0–1
    var colorHex: UInt
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
    var customZones: [CustomZone] = []
    /// Folder riwayat untuk sesi ini (agar edit zona ikut tersimpan). nil = belum tersimpan.
    var historyFolder: String? = nil
    /// Jumlah kamera untuk ditampilkan saat melihat riwayat (kamera asli tak dimuat ulang).
    var overrideCameraCount: Int? = nil

    // Turunan
    var venueWidthM: Double { Double(widthM) ?? 0 }
    var venueHeightM: Double { Double(heightM) ?? 0 }
    var timelineMin: Double {
        cameras.map { max(0, -$0.timeOffsetSec) }.max() ?? 0
    }
    var timelineMax: Double {
        cameras.compactMap {
            $0.durationSec > 0 ? $0.durationSec - $0.timeOffsetSec : nil
        }.min() ?? 0
    }
    var previewURL: URL? { cameras.first { $0.url != nil }?.url }
    /// Semua kamera yang punya file (untuk preview per-video di trim card, bila dipakai).
    var previews: [TrimCameraPreview] {
        cameras.compactMap { camera in
            camera.url.map {
                TrimCameraPreview(
                    id: camera.id,
                    label: camera.label,
                    url: $0,
                    offsetSec: camera.timeOffsetSec
                )
            }
        }
    }
    var allCalibrated: Bool { !cameras.isEmpty && cameras.allSatisfy { $0.isCalibrated } }
    var calibrationFloorSize: PixelSize {
        if !usesScaledCanvas, let floorPlanPixelSize, floorPlanPixelSize.isValid { return floorPlanPixelSize }
        return PixelSize(width: 1000, height: 1000)
    }

    func normalizeTrim() {
        let lower = timelineMin
        let upper = timelineMax
        guard upper > lower else { trimStartSec = lower; trimEndSec = lower; return }
        trimStartSec = min(max(lower, trimStartSec), upper)
        if trimEndSec <= trimStartSec || trimEndSec > upper {
            trimEndSec = min(upper, trimStartSec + 600)
        }
    }

    func reset() {
        cameras = []
        floorPlanURL = nil; floorPlanName = nil; floorPlanPixelSize = nil; usesScaledCanvas = true
        jobId = nil; stage = ""; progress = 0
        isProcessing = false; errorMessage = nil; result = nil
        customZones = []
        historyFolder = nil
        overrideCameraCount = nil
    }
}
