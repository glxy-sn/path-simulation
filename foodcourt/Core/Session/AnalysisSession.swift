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
    var isCalibrated: Bool { imagePoints.count == 4 && planePoints.count == 4 }
}

/// Hasil yang sudah dipetakan ke model UI (siap dipakai layar Hasil).
struct AnalysisResult {
    var summary: VenueSummary
    var zones: [ZoneRank]
    var stops: [StopPoint]
    var occupancy: [OccupancyPoint]
    var heatmapURL: URL?
    var pathVideoURL: URL?
    var overlayVideos: [(cam: String, url: URL)]
}

@Observable
final class AnalysisSession {
    // Venue
    var venueName = ""
    var venueType: VenueType = .pujasera
    var widthM = "20"
    var heightM = "15"
    var mode: AnalysisMode = .lengkap

    // Kamera + kalibrasi
    var cameras: [SessionCamera] = []

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
        jobId = nil; stage = ""; progress = 0
        isProcessing = false; errorMessage = nil; result = nil
    }
}
