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
    var observations: [CGPoint] = []
}

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

    // Turunan
    var venueWidthM: Double { Double(widthM) ?? 0 }
    var venueHeightM: Double { Double(heightM) ?? 0 }
    var timelineMax: Double { cameras.compactMap { $0.durationSec > 0 ? $0.durationSec : nil }.min() ?? 0 }
    var previewURL: URL? { cameras.first { $0.url != nil }?.url }
    /// Semua kamera yang punya file (untuk preview per-video di trim card, bila dipakai).
    var previews: [(label: String, url: URL)] {
        cameras.compactMap { c in c.url.map { (label: c.label, url: $0) } }
    }
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
        customZones = []
    }
}
