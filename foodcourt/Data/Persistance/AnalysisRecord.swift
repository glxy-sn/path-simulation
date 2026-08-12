//
//  AnalysisRecord.swift
//  foodcourt
//
//  Created by Shafa Tiara on 11/08/26.
//

import Foundation
import SwiftData

@Model
final class AnalysisRecord {
    var id: UUID
    var date: Date
    var venueName: String
    var venueType: String
    var widthM: Double
    var heightM: Double
    var durationSec: Double
    var cameraCount: Int
    var mode: String
    var totalVisitors: Int
    var avgDwellSeconds: Int
    var peakOccupancy: Int
    var captureRate: Double
    var folder: String        // subfolder artifact+json di Application Support

    init(id: UUID = UUID(), date: Date = .now,
         venueName: String, venueType: String,
         widthM: Double, heightM: Double, durationSec: Double,
         cameraCount: Int, mode: String,
         totalVisitors: Int, avgDwellSeconds: Int, peakOccupancy: Int, captureRate: Double,
         folder: String = "") {
        self.id = id
        self.date = date
        self.venueName = venueName
        self.venueType = venueType
        self.widthM = widthM
        self.heightM = heightM
        self.durationSec = durationSec
        self.cameraCount = cameraCount
        self.mode = mode
        self.totalVisitors = totalVisitors
        self.avgDwellSeconds = avgDwellSeconds
        self.peakOccupancy = peakOccupancy
        self.captureRate = captureRate
        self.folder = folder
    }
}

extension AnalysisRecord {
    convenience init(from s: AnalysisSession, result r: AnalysisResult) {
        self.init(
            venueName: s.venueName.isEmpty ? "Venue" : s.venueName,
            venueType: s.venueType.rawValue,
            widthM: s.venueWidthM, heightM: s.venueHeightM,
            durationSec: max(0, s.trimEndSec - s.trimStartSec),
            cameraCount: s.cameras.count,
            mode: s.mode.rawValue,
            totalVisitors: r.summary.totalVisitors,
            avgDwellSeconds: r.summary.avgDwellSeconds,
            peakOccupancy: r.summary.peakOccupancy,
            captureRate: r.summary.captureRate
        )
    }

    var dateText: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy, HH:mm"
        return df.string(from: date)
    }
    var avgDwellText: String { timecode(Double(avgDwellSeconds)) }
    var captureText: String { "\(Int((captureRate * 100).rounded()))%" }
}
