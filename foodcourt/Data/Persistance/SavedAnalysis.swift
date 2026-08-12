//
//  SavedAnalysis.swift
//  foodcourt
//
//  Created by Shafa Tiara on 11/08/26.
//

import Foundation
import CoreGraphics

struct SavedAnalysis: Codable {
    /// Optional agar riwayat sebelum integrasi explanatory tetap dapat dibuka.
    var jobId: String?
    // venue
    var venueName: String
    var venueType: String
    var widthM: Double
    var heightM: Double
    var startSec: Double
    var durationSec: Double
    var cameraCount: Int
    var usesScaledCanvas: Bool
    // summary
    var totalVisitors: Int
    var avgDwellSeconds: Int
    var peakOccupancy: Int
    var captureRate: Double
    // data
    var zones: [SZone]
    var stops: [SStop]
    var occupancy: [SOcc]
    var blobs: [SBlob]
    var paths: [SPath]
    /// Opsional agar riwayat yang dibuat sebelum data observasi/zona custom tetap dapat dibuka.
    var observations: [[Double]]?
    var customZones: [SCustomZone]?
    var identityQuality: SIdentityQuality?
    // artifact (nama file relatif di dalam folder; nil kalau tak ada)
    var heatmapFile: String?
    var pathVideoFile: String?
    var combinedVideoFile: String?
    var fusionDiagnosticsFile: String?
    var overlays: [SOverlay]
    var floorPlanFile: String?
    var tables: [STable]?

    struct SZone: Codable { var code: String; var visits: Int; var share: Double
        var x: Double; var y: Double; var w: Double; var h: Double; var color: UInt }
    struct SStop: Codable { var name: String; var dwell: Int; var x: Double = 0; var y: Double = 0 }
    struct SOcc: Codable { var minute: Int; var count: Int }
    struct SBlob: Codable { var x: Double; var y: Double; var intensity: Double; var radius: Double }
    struct SPath: Codable { var hue: Double; var pts: [[Double]] }   // [x,y,t]
    struct SCustomZone: Codable { var id: UUID? = nil; var name: String; var x: Double; var y: Double
        var w: Double; var h: Double; var color: UInt }
    struct SIdentityQuality: Codable {
        var globalIDs: Int; var localStitches: Int; var overlapMerges: Int; var handoverMerges: Int
        var unmatchedTracklets: Int; var filteredTracklets: Int
        var highConfidence: Int; var mediumConfidence: Int; var lowConfidence: Int; var singleCamera: Int
        var calibrationWarnings: [String]
    }
    struct SOverlay: Codable { var cam: String; var file: String }
    struct STable: Codable {
        var id: UUID; var label: String
        var x: Double; var y: Double; var width: Double; var height: Double
        var verified: Bool
    }
}

// MARK: - Bangun dari sesi + hasil (dipanggil di main)

extension SavedAnalysis {
    init(from s: AnalysisSession, result r: AnalysisResult) {
        jobId = r.jobId ?? s.jobId
        venueName = s.venueName; venueType = s.venueType.rawValue
        widthM = s.venueWidthM; heightM = s.venueHeightM
        startSec = s.trimStartSec; durationSec = max(0, s.trimEndSec - s.trimStartSec)
        cameraCount = s.cameras.count
        usesScaledCanvas = s.usesScaledCanvas
        totalVisitors = r.summary.totalVisitors
        avgDwellSeconds = r.summary.avgDwellSeconds
        peakOccupancy = r.summary.peakOccupancy
        captureRate = r.summary.captureRate
        zones = r.zones.map { SZone(code: $0.code, visits: $0.visits, share: $0.share,
                                    x: $0.rect.minX, y: $0.rect.minY, w: $0.rect.width, h: $0.rect.height,
                                    color: $0.colorHex) }
        stops = r.stops.map { SStop(name: $0.name, dwell: $0.dwellSeconds, x: $0.point.x, y: $0.point.y) }
        occupancy = r.occupancy.map { SOcc(minute: $0.minute, count: $0.count) }
        blobs = r.blobs.map { SBlob(x: $0.x, y: $0.y, intensity: $0.intensity, radius: $0.radius) }
        paths = r.paths.map { p in
            var pts: [[Double]] = []
            for (i, pt) in p.points.enumerated() {
                pts.append([Double(pt.x), Double(pt.y), i < p.times.count ? p.times[i] : 0])
            }
            return SPath(hue: p.hue, pts: pts)
        }
        observations = r.observations.map { [Double($0.trackId), Double($0.point.x), Double($0.point.y), $0.t] }
        customZones = s.customZones.map { SCustomZone(id: $0.id, name: $0.name, x: $0.rect.minX, y: $0.rect.minY,
                                                      w: $0.rect.width, h: $0.rect.height, color: $0.colorHex) }
        identityQuality = r.identityQuality.map {
            SIdentityQuality(
                globalIDs: $0.globalIDs, localStitches: $0.localStitches,
                overlapMerges: $0.overlapMerges, handoverMerges: $0.handoverMerges,
                unmatchedTracklets: $0.unmatchedTracklets, filteredTracklets: $0.filteredTracklets,
                highConfidence: $0.highConfidence, mediumConfidence: $0.mediumConfidence,
                lowConfidence: $0.lowConfidence, singleCamera: $0.singleCamera,
                calibrationWarnings: $0.calibrationWarnings
            )
        }
        // nama file artifact (diunduh terpisah)
        heatmapFile = r.heatmapURL != nil ? "heatmap.png" : nil
        pathVideoFile = r.pathVideoURL != nil ? "path.mp4" : nil
        combinedVideoFile = r.combinedVideoURL != nil ? "combined.mp4" : nil
        fusionDiagnosticsFile = r.fusionDiagnosticsURL != nil ? "fusion_diagnostics.json" : nil
        overlays = r.overlayVideos.enumerated().map { i, ov in SOverlay(cam: ov.cam, file: "overlay_\(i).mp4") }
        floorPlanFile = (!s.usesScaledCanvas && s.floorPlanURL != nil) ? "floorplan\(Self.ext(s.floorPlanURL))" : nil
        tables = s.tableAnnotations.map {
            STable(id: $0.id, label: $0.label, x: $0.rectNormalized.minX, y: $0.rectNormalized.minY,
                   width: $0.rectNormalized.width, height: $0.rectNormalized.height, verified: $0.verified)
        }
    }

    private static func ext(_ url: URL?) -> String {
        let e = url?.pathExtension ?? ""
        return e.isEmpty ? ".png" : ".\(e)"
    }
}

struct LoadedAnalysis {
    var jobId: String?
    var result: AnalysisResult
    var customZones: [CustomZone]
    var venueName: String
    var venueType: String
    var widthM: String
    var heightM: String
    var usesScaledCanvas: Bool
    var floorPlanURL: URL?
    var cameraCount: Int
    var durationSec: Double
    var tables: [TableAnnotation]
}

// MARK: - Store

enum HistoryStore {
    static func baseDir() -> URL {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSup.appendingPathComponent("Foodcourt/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func folderURL(_ folder: String) -> URL {
        baseDir().appendingPathComponent(folder, isDirectory: true)
    }

    /// Sinkron di main: tulis JSON + salin denah (selagi izin file aktif). Cepat.
    static func writeMeta(_ saved: SavedAnalysis, folder: String, floorPlanSource: URL?) {
        let dir = folderURL(folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let src = floorPlanSource, let name = saved.floorPlanFile {
            try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(saved) {
            try? data.write(to: dir.appendingPathComponent("result.json"))
        }
    }

    /// Async (detached): unduh artifact video/heatmap dari server ke folder app.
    static func downloadArtifacts(_ items: [(name: String, url: URL)], folder: String) async {
        let dir = folderURL(folder)
        for item in items {
            do {
                let (data, _) = try await URLSession.shared.data(from: item.url)
                try data.write(to: dir.appendingPathComponent(item.name))
            } catch {
                // artifact gagal diunduh -> lewati; load nanti graceful (file tak ada)
            }
        }
    }

    /// Muat hasil lengkap dari folder (untuk dibuka lagi).
    static func load(folder: String) -> LoadedAnalysis? {
        let dir = folderURL(folder)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("result.json")),
              let s = try? JSONDecoder().decode(SavedAnalysis.self, from: data) else { return nil }

        func fileURL(_ name: String?) -> URL? {
            guard let name else { return nil }
            let u = dir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }

        let palette: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]
        let zones = s.zones.enumerated().map { i, z in
            ZoneRank(rank: i + 1, code: z.code, visits: z.visits, share: z.share,
                     rect: CGRect(x: z.x, y: z.y, width: z.w, height: z.h),
                     colorHex: z.color == 0 ? palette[i % palette.count] : z.color)
        }
        let result = AnalysisResult(
            jobId: s.jobId,
            summary: VenueSummary(totalVisitors: s.totalVisitors, avgDwellSeconds: s.avgDwellSeconds,
                                  peakOccupancy: s.peakOccupancy, captureRate: s.captureRate),
            zones: zones,
            stops: s.stops.map { StopPoint(name: $0.name, dwellSeconds: $0.dwell, point: CGPoint(x: $0.x, y: $0.y)) },
            occupancy: s.occupancy.map { OccupancyPoint(minute: $0.minute, count: $0.count) },
            heatmapURL: fileURL(s.heatmapFile),
            pathVideoURL: fileURL(s.pathVideoFile),
            combinedVideoURL: fileURL(s.combinedVideoFile),
            overlayVideos: s.overlays.compactMap { o in fileURL(o.file).map { (cam: o.cam, url: $0) } },
            blobs: s.blobs.map { HeatBlob(x: $0.x, y: $0.y, intensity: $0.intensity, radius: $0.radius) },
            paths: s.paths.map { p in
                PathTrace(points: p.pts.map { CGPoint(x: $0[0], y: $0[1]) },
                          hue: p.hue,
                          times: p.pts.map { $0.count > 2 ? $0[2] : 0 })
            },
            identityQuality: s.identityQuality.map {
                IdentityQualitySummary(
                    globalIDs: $0.globalIDs, localStitches: $0.localStitches,
                    overlapMerges: $0.overlapMerges, handoverMerges: $0.handoverMerges,
                    unmatchedTracklets: $0.unmatchedTracklets, filteredTracklets: $0.filteredTracklets,
                    highConfidence: $0.highConfidence, mediumConfidence: $0.mediumConfidence,
                    lowConfidence: $0.lowConfidence, singleCamera: $0.singleCamera,
                    calibrationWarnings: $0.calibrationWarnings
                )
            },
            fusionDiagnosticsURL: fileURL(s.fusionDiagnosticsFile),
            observations: (s.observations ?? []).compactMap {
                $0.count >= 4 ? TrackObservation(trackId: Int($0[0]), point: CGPoint(x: $0[1], y: $0[2]), t: $0[3]) : nil
            }
        )
        let customZones = (loadZones(folder: folder) ?? (s.customZones ?? []).map {
            CustomZone(id: $0.id ?? UUID(), name: $0.name,
                       rect: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), colorHex: $0.color)
        })
        func numStr(_ d: Double) -> String { d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d) }
        return LoadedAnalysis(
            jobId: s.jobId,
            result: result, customZones: customZones,
            venueName: s.venueName, venueType: s.venueType,
            widthM: numStr(s.widthM), heightM: numStr(s.heightM),
            usesScaledCanvas: s.usesScaledCanvas,
            floorPlanURL: fileURL(s.floorPlanFile),
            cameraCount: s.cameraCount,
            durationSec: s.durationSec,
            tables: (s.tables ?? []).map {
                TableAnnotation(id: $0.id, label: $0.label,
                                rectNormalized: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                                verified: $0.verified)
            }
        )
    }

    // Zona disimpan di file terpisah (kecil) agar edit real-time cepat & tetap persist.
    static func saveZones(folder: String, _ zones: [CustomZone]) {
        guard !folder.isEmpty else { return }
        let arr = zones.map { ["id": $0.id.uuidString, "name": $0.name,
                               "x": $0.rect.minX, "y": $0.rect.minY,
                               "w": $0.rect.width, "h": $0.rect.height, "color": $0.colorHex] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? data.write(to: folderURL(folder).appendingPathComponent("zones.json"))
        }
    }

    static func loadZones(folder: String) -> [CustomZone]? {
        let u = folderURL(folder).appendingPathComponent("zones.json")
        guard let data = try? Data(contentsOf: u),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { d in
            guard let name = d["name"] as? String,
                  let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
            let color = (d["color"] as? UInt) ?? UInt((d["color"] as? Int) ?? 0xB46A72)
            let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return CustomZone(id: id, name: name,
                              rect: CGRect(x: x, y: y, width: w, height: h), colorHex: color)
        }
    }

    static func delete(folder: String) {
        try? FileManager.default.removeItem(at: folderURL(folder))
    }
}
