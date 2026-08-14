//
//  ResultsView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import Charts
import AVKit
import AppKit
import UniformTypeIdentifiers

enum ResultVisual: String, CaseIterable, Identifiable {
    case boundingBox = "Detection"
    case path = "Path Simulation"
    case heatmap = "Heatmap"
    case zona = "Zones"
    var id: String { rawValue }
}

struct ResultsView: View {
    var isHistory: Bool = false
    var onClose: (() -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil
    var isChatVisible: Bool = false
    @Environment(\.uiScale) private var scale
    @Environment(AnalysisSession.self) private var session
    @Environment(AppRouter.self) private var router
    @State private var visual: ResultVisual = .boundingBox

    // Data: hasil engine bila ada, kalau tidak pakai contoh.
    private var summary: VenueSummary { session.result?.summary ?? SampleResult.summary }
    private var zones: [ZoneRank] { session.result?.zones ?? SampleResult.zones }
    private var stops: [StopPoint] { session.result?.stops ?? SampleResult.stops }
    private var occupancy: [OccupancyPoint] { session.result?.occupancy ?? SampleResult.occupancy }

    private var heatmapURL: URL? { session.result?.heatmapURL }
    private var pathVideoURL: URL? { session.result?.pathVideoURL }
    private var boundingVideoURL: URL? {
        session.result?.combinedVideoURL ?? session.result?.overlayVideos.first?.url
    }
    private var hasResult: Bool { session.result != nil }
    private var identityQuality: IdentityQualitySummary? { session.result?.identityQuality }

    /// Floor map untuk background Zona (kalau user pakai floor plan, bukan canvas).
    private var floorMapImage: NSImage? {
        guard !session.usesScaledCanvas, let url = session.floorPlanURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var blobs: [HeatBlob] {
        let b = session.result?.blobs ?? []
        return b.isEmpty ? (hasResult ? [] : SampleResult.blobs) : b
    }
    private var paths: [PathTrace] {
        let p = session.result?.paths ?? []
        return p.isEmpty ? (hasResult ? [] : SampleResult.paths) : p
    }
    private var observations: [TrackObservation] { session.result?.observations ?? [] }

    /// Lintasan per orang (rekonstruksi dari observasi ber-track) — untuk ringkasan path.
    private var trajectories: [[CGPoint]] {
        let byTrack = Dictionary(grouping: observations, by: { $0.trackId })
        return byTrack.values
            .map { obs in obs.sorted { $0.t < $1.t }.map { $0.point } }
            .filter { $0.count >= 2 }
    }
    private var flowField: [FlowArrow] { Foodcourt_flowField(trajectories) }

    private func obsCount(_ rect: CGRect) -> Int {
        observations.reduce(0) { $0 + (rect.contains($1.point) ? 1 : 0) }
    }

    /// Metrik per zona dari observasi ber-track: jumlah orang unik + rata-rata durasi.
    private func zoneMetrics(_ rect: CGRect) -> (people: Int, avgDurSec: Double, count: Int) {
        Foodcourt_zoneMetrics(rect, observations)
    }

    private var totalUniquePeople: Int {
        Set(observations.map { $0.trackId }).count
    }

    private var rankedCustomZones: [(zone: CustomZone, people: Int, avgDur: Double)] {
        session.customZones
            .map { z -> (zone: CustomZone, people: Int, avgDur: Double) in
                let m = zoneMetrics(z.rect)
                return (zone: z, people: m.people, avgDur: m.avgDurSec)
            }
            .sorted { $0.people > $1.people }
    }

    /// Rasio venue (lebar : panjang) untuk membentuk area visual lantai.
    private var venueAspect: CGFloat {
        let w = session.venueWidthM, h = session.venueHeightM
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return CGFloat(w / h)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                header
                metrics
                mediaCard
                HStack(alignment: .top, spacing: Space.l * scale) {
                    rankingCard.relativeWidth(0.40)
                    occupancyCard.frame(maxWidth: .infinity)
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
        .onChange(of: session.customZones) { _, zones in
            if let folder = session.historyFolder { HistoryStore.saveZones(folder: folder, zones) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s) {
            if isHistory, let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.callout.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.s))
                }
                .buttonStyle(.plain)
                .help("Back to history list")
            }
            SectionHeader(title: isHistory ? "Analysis History" : "Analysis Results", subtitle: subtitle)
            if !isHistory {
                Button("New Analysis", systemImage: "plus") {
                    session.reset(); router.startNew()
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            Button("Export", systemImage: "square.and.arrow.up") { exportBundle() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(Theme.accentFill)
                .disabled(session.result == nil)
                .help("Save a .zip containing the JSON and CSV report")
            if !isChatVisible, let onOpenChat {
                Button("Ask Data", systemImage: "bubble.left.and.text.bubble.right") {
                    onOpenChat()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open Ask Data panel")
            }
        }
    }

    // MARK: - Export

    private func defaultName() -> String {
        let base = session.venueName.isEmpty ? "foodcourt" : session.venueName
        let safe = base.replacingOccurrences(of: " ", with: "_")
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmm"
        return "\(safe)_\(df.string(from: Date()))"
    }

    private func save(name: String, type: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    /// One button, one file: a .zip holding the full JSON and the spreadsheet CSV.
    private func exportBundle() {
        guard session.result != nil,
              let json = buildJSON(),
              let csv = buildCSV().data(using: .utf8) else { return }

        let name = defaultName()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = staging.appendingPathComponent(name)
        defer { try? fm.removeItem(at: staging) }

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appendingPathComponent("analysis.json"))
            try csv.write(to: folder.appendingPathComponent("summary.csv"))
        } catch { return }

        // NSFileCoordinator's .forUploading hands back a zipped copy of the folder,
        // so no third-party archiver is needed.
        var archive: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: [.forUploading],
                                       error: &coordinationError) { zipped in
            archive = try? Data(contentsOf: zipped)
        }
        guard let data = archive else { return }
        save(name: name + ".zip", type: .zip, data: data)
    }

    private func buildJSON() -> Data? {
        guard let r = session.result else { return nil }
        var dict: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "jobId": r.jobId ?? session.jobId ?? "",
            "venue": ["name": session.venueName, "type": session.venueType.rawValue,
                      "widthM": session.venueWidthM, "heightM": session.venueHeightM],
            "window": ["startSec": session.trimStartSec,
                       "durationSec": max(0, session.trimEndSec - session.trimStartSec)],
            "cameras": session.cameras.map { cam in
                ["label": cam.label,
                 "resolution": cam.resolution,
                 "durationSec": cam.durationSec,
                 "timeOffsetSec": cam.timeOffsetSec,
                 "isCalibrated": cam.isCalibrated] as [String: Any]
            },
            "summary": ["totalVisitors": r.summary.totalVisitors,
                        "avgDwellSeconds": r.summary.avgDwellSeconds,
                        "peakOccupancy": r.summary.peakOccupancy,
                        "captureRate": r.summary.captureRate],
            "zones": r.zones.map { ["rank": $0.rank, "code": $0.code, "name": $0.name,
                                    "visits": $0.visits, "share": $0.share,
                                    "rect": ["x": $0.rect.minX, "y": $0.rect.minY,
                                             "w": $0.rect.width, "h": $0.rect.height]] },
            "customZones": session.customZones.map { ["id": $0.id.uuidString, "name": $0.name,
                                                      "rect": ["x": $0.rect.minX, "y": $0.rect.minY,
                                                               "w": $0.rect.width, "h": $0.rect.height]] },
            "stopPoints": r.stops.map { ["name": $0.name, "dwellSeconds": $0.dwellSeconds,
                                         "x": Double($0.point.x), "y": Double($0.point.y)] },
            "occupancy": r.occupancy.map { ["minute": $0.minute, "count": $0.count] },
        ]
        if let q = r.identityQuality {
            dict["identityQuality"] = [
                "globalIDs": q.globalIDs,
                "localStitches": q.localStitches,
                "overlapMerges": q.overlapMerges,
                "handoverMerges": q.handoverMerges,
                "unmatchedTracklets": q.unmatchedTracklets,
                "filteredTracklets": q.filteredTracklets,
                "highConfidence": q.highConfidence,
                "mediumConfidence": q.mediumConfidence,
                "lowConfidence": q.lowConfidence,
                "singleCamera": q.singleCamera,
                "calibrationWarnings": q.calibrationWarnings,
            ]
        }
        dict["paths"] = r.paths.enumerated().map { (i, p) -> [String: Any] in
            var pts: [[String: Any]] = []
            for (idx, pt) in p.points.enumerated() {
                let t = idx < p.times.count ? p.times[idx] : 0
                pts.append(["x": Double(pt.x), "y": Double(pt.y), "t": t])
            }
            return ["id": i, "hue": p.hue, "points": pts]
        }
        return try? JSONSerialization.data(withJSONObject: dict,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    private func buildCSV() -> String {
        guard let r = session.result else { return "" }
        func esc(_ v: String) -> String {
            v.contains(",") || v.contains("\"")
                ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\""
                : v
        }

        var s = "Food Court Analysis Report\n"
        s += "Venue,\(esc(session.venueName))\n"
        s += "Venue Type,\(esc(session.venueType.rawValue))\n"
        s += "Size (m),\(session.venueWidthM) x \(session.venueHeightM)\n"
        s += "Generated At,\(ISO8601DateFormatter().string(from: Date()))\n"
        s += "Window Start (sec),\(session.trimStartSec)\n"
        s += "Window Duration (sec),\(max(0, session.trimEndSec - session.trimStartSec))\n\n"

        s += "Metric,Value\n"
        s += "Total Visitors,\(r.summary.totalVisitors)\n"
        s += "Avg. Time Spent (sec),\(r.summary.avgDwellSeconds)\n"
        s += "Busiest Moment,\(r.summary.peakOccupancy)\n"
        s += "Capture Rate,\(r.summary.captureRate)\n\n"

        s += "Camera,Resolution,Duration (sec),Time Offset (sec),Calibrated\n"
        for cam in session.cameras {
            s += "\(esc(cam.label)),\(cam.resolution),\(cam.durationSec),\(cam.timeOffsetSec),\(cam.isCalibrated)\n"
        }

        s += "\nRank,Zone,Visits,Share\n"
        for z in r.zones { s += "\(z.rank),\(esc(z.name)),\(z.visits),\(z.share)\n" }

        if !session.customZones.isEmpty {
            s += "\nCustom Zone,x,y,w,h\n"
            for z in session.customZones {
                s += "\(esc(z.name)),\(z.rect.minX),\(z.rect.minY),\(z.rect.width),\(z.rect.height)\n"
            }
        }

        s += "\nStop Point,Dwell (sec),x,y\n"
        for st in r.stops { s += "\(esc(st.name)),\(st.dwellSeconds),\(st.point.x),\(st.point.y)\n" }

        s += "\nMinute,Occupancy\n"
        for o in r.occupancy { s += "\(o.minute),\(o.count)\n" }

        if let q = r.identityQuality {
            s += "\nIdentity Quality,Value\n"
            s += "Global IDs,\(q.globalIDs)\n"
            s += "Local Stitches,\(q.localStitches)\n"
            s += "Overlap Merges,\(q.overlapMerges)\n"
            s += "Handover Merges,\(q.handoverMerges)\n"
            s += "Unmatched Tracklets,\(q.unmatchedTracklets)\n"
            s += "Filtered Tracklets,\(q.filteredTracklets)\n"
            s += "High Confidence,\(q.highConfidence)\n"
            s += "Medium Confidence,\(q.mediumConfidence)\n"
            s += "Low Confidence,\(q.lowConfidence)\n"
            s += "Single Camera,\(q.singleCamera)\n"
        }
        return s
    }

    private var subtitle: String {
        if hasResult {
            let name = session.venueName.isEmpty ? "Venue" : session.venueName
            let dur = timecode(session.trimEndSec - session.trimStartSec)
            let cams = session.overrideCameraCount ?? session.cameras.count
            return "\(name) · \(cams) cameras · duration \(dur)"
        }
        return "Sample data — run an analysis for real results."
    }

    private var metrics: some View {
        HStack(spacing: Space.m * scale) {
            MetricTile(title: "Total Visitors", value: "\(summary.totalVisitors)", systemImage: "person.2.fill")
            MetricTile(title: "Avg. Time Spent", value: summary.avgDwellText, systemImage: "clock.fill", tint: .orange)
            MetricTile(title: "Busiest Moment", value: "\(summary.peakOccupancy) people", systemImage: "chart.line.uptrend.xyaxis", tint: .pink)
        }
    }
    
    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Visualization").font(.headline)
                Spacer()
                Picker("", selection: $visual) {
                    ForEach(ResultVisual.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }

            Group {
                switch visual {
                case .boundingBox:
                    ZStack {
                        if let url = boundingVideoURL { FileVideoPlayer(url: url) }
                        else { BoundingBoxContent(); VideoChrome() }
                    }
                    .frame(height: min(400, max(300, 360 * scale)))
                    .frame(maxWidth: .infinity)
                case .path:
                    PathTab(paths: paths, trajectories: trajectories, flow: flowField,
                            stops: stops, background: floorMapImage,
                            widthM: session.venueWidthM, heightM: session.venueHeightM)
                        .aspectRatio(venueAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                case .heatmap:
                    HeatmapTab(observations: observations, fallbackBlobs: blobs, background: floorMapImage)
                        .aspectRatio(venueAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                case .zona:
                    ZonaEditor(session: session,
                               observations: observations,
                               background: floorMapImage)
                        .aspectRatio(venueAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )

            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var caption: String {
        switch visual {
        case .boundingBox:
            return boundingVideoURL != nil
                ? "Detection video + global cross-camera IDs (grid + BEV when multi-camera)."
                : "Sample — run an analysis for real footage."
        case .path:    return "Visitor movement paths projected on the floor plan."
        case .heatmap: return "Movement density projected on the floor plan."
        case .zona:    return "Zones on the floor plan. Colors match the ranking list below."
        }
    }

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Most Visited Zones").font(.headline)
                if session.customZones.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("No zones yet.")
                            .font(.callout.weight(.medium))
                        Text("Go to the Zones tab to draw the areas you want to analyze (e.g. cashier, seating). People count and average duration are computed automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        GhostButton(title: "Go to Zones", systemImage: "square.dashed") {
                            visual = .zona
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.s)
                } else {
                    ForEach(Array(rankedCustomZones.enumerated()), id: \.element.zone.id) { i, item in
                        HStack(spacing: Space.s) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: item.zone.colorHex))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(item.zone.name).font(.callout).lineLimit(1)
                                    if i == 0 && item.people > 0 {
                                        Text("★ Favorite").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                                    }
                                }
                                Text("rata-rata \(timecode(item.avgDur))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.people) people").font(.callout.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Longest Stops").font(.headline)
                ForEach(stops) { stop in
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.orange)
                        Text(stop.name).font(.callout)
                        Spacer()
                        Text(stop.dwellText).font(.callout.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
        .card()
    }

    private var occupancyCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Occupancy Over Time").font(.headline)
            Chart(occupancy) { point in
                AreaMark(x: .value("Minute", point.minute), y: .value("People", point.count))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Minute", point.minute), y: .value("People", point.count))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxisLabel("minute")
            .chartYAxisLabel("people")
            .frame(minHeight: 220)
        }
        .card()
    }
}

// MARK: - Player & gambar dari file (artifact engine)

/// AVPlayerView (AppKit) → punya tombol full-screen + Picture-in-Picture bawaan.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.allowsPictureInPicturePlayback = true
        if #available(macOS 13.0, *) {
            v.showsFullScreenToggleButton = true
        }
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private struct FileVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer
    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }
    var body: some View {
        PlayerView(player: player)
            .onDisappear { player.pause() }
    }
}

private struct FileImage: View {
    let url: URL
    var body: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                ZStack { Color.black; ProgressView().tint(.white) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Heatmap 2 opsi (jumlah orang vs lama singgah)

/// Bangun blob heatmap dari observasi.
/// mode 0 = jumlah ORANG unik (traffic); 1 = LAMA singgah (∝ waktu); 2 = GABUNGAN (keduanya dinormalisasi).
func Foodcourt_heatBlobs(_ obs: [TrackObservation], mode: Int, top: Int = 40) -> [HeatBlob] {
    guard !obs.isEmpty else { return [] }
    let GW = 56, GH = 42
    var count = [Double](repeating: 0, count: GW * GH)
    var tracks = Array(repeating: Set<Int>(), count: GW * GH)
    for o in obs {
        let cx = min(GW - 1, max(0, Int(o.point.x * Double(GW))))
        let cy = min(GH - 1, max(0, Int(o.point.y * Double(GH))))
        let idx = cy * GW + cx
        count[idx] += 1
        tracks[idx].insert(o.trackId)
    }
    let traffic = tracks.map { Double($0.count) }
    let dwell = count
    func norm(_ a: [Double]) -> [Double] { let m = a.max() ?? 1; return m > 0 ? a.map { $0 / m } : a }

    var work: [Double]
    switch mode {
    case 1:  work = dwell
    case 2:  let nt = norm(traffic), nd = norm(dwell); work = zip(nt, nd).map { 0.5 * $0 + 0.5 * $1 }
    default: work = traffic
    }
    let maxv = work.max() ?? 1
    guard maxv > 0 else { return [] }
    var blobs: [HeatBlob] = []
    for _ in 0..<top {
        guard let idx = work.indices.max(by: { work[$0] < work[$1] }), work[idx] > 0 else { break }
        let cx = idx % GW, cy = idx / GW
        blobs.append(HeatBlob(x: (Double(cx) + 0.5) / Double(GW),
                              y: (Double(cy) + 0.5) / Double(GH),
                              intensity: work[idx] / maxv, radius: 0.06))
        for dy in -1...1 { for dx in -1...1 {
            let nx = cx + dx, ny = cy + dy
            if nx >= 0, nx < GW, ny >= 0, ny < GH { work[ny * GW + nx] = 0 }
        }}
    }
    return blobs
}

private struct HeatmapTab: View {
    let observations: [TrackObservation]
    let fallbackBlobs: [HeatBlob]
    var background: NSImage? = nil
    @State private var mode = 2   // default: gabungan (Activity)

    var body: some View {
        let blobs = observations.isEmpty ? fallbackBlobs
                                         : Foodcourt_heatBlobs(observations, mode: mode)
        ZStack(alignment: .top) {
            HeatmapView(blobs: blobs, background: background)
                .overlay(alignment: .bottomTrailing) { HeatmapLegend().padding(Space.s) }

            Picker("", selection: $mode) {
                Text("Activity").tag(2)
                Text("Foot Traffic").tag(0)
                Text("Time Spent").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(Space.s)
        }
    }
}

// MARK: - Path summary (jalur utama + heatmap garis + stop point)

struct FlowArrow: Identifiable {
    let id = UUID()
    let at: CGPoint
    let dx: Double
    let dy: Double
    let weight: Double
}

/// Medan aliran: rata-rata arah gerak orang di tiap sel grid.
/// Menjawab "sepanjang waktu, rata-rata orang di area ini bergerak ke mana".
func Foodcourt_flowField(_ trajs: [[CGPoint]], gx: Int = 14, gy: Int = 10,
                         minCoherence: Double = 0.55, minSteps: Double = 4) -> [FlowArrow] {
    var sumX = [Double](repeating: 0, count: gx * gy)
    var sumY = [Double](repeating: 0, count: gx * gy)
    var sumU = [Double](repeating: 0, count: gx * gy)   // jumlah vektor satuan
    var sumV = [Double](repeating: 0, count: gx * gy)
    var cnt  = [Double](repeating: 0, count: gx * gy)
    for t in trajs where t.count >= 2 {
        for i in 1..<t.count {
            let a = t[i - 1], b = t[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < 0.002 || d > 0.15 { continue }        // buang noise & lompatan ID
            let cx = min(gx - 1, max(0, Int(a.x * Double(gx))))
            let cy = min(gy - 1, max(0, Int(a.y * Double(gy))))
            let idx = cy * gx + cx
            sumX[idx] += dx; sumY[idx] += dy; cnt[idx] += 1
            sumU[idx] += dx / d; sumV[idx] += dy / d
        }
    }
    let maxC = cnt.max() ?? 1
    var arrows: [FlowArrow] = []
    // Hanya petak yang arahnya seragam yang dapat panah. Kekompakan diukur dari
    // panjang jumlah vektor SATUAN dibagi jumlah langkah: 1 = semua orang searah,
    // 0 = arahnya campur aduk. Ini beda dari besar perpindahan rata-rata, yang
    // ikut terpengaruh cepat-lambatnya orang berjalan.
    for idx in 0..<(gx * gy) where cnt[idx] >= minSteps {
        let vx = sumX[idx] / cnt[idx], vy = sumY[idx] / cnt[idx]
        let mag = (vx * vx + vy * vy).squareRoot()
        if mag < 0.004 { continue }                      // tak ada arah dominan (diam)
        let kekompakan = (sumU[idx] * sumU[idx] + sumV[idx] * sumV[idx]).squareRoot() / cnt[idx]
        if kekompakan < minCoherence { continue }        // arahnya campur -> tidak dipercaya
        let cx = idx % gx, cy = idx / gx
        arrows.append(FlowArrow(
            at: CGPoint(x: (Double(cx) + 0.5) / Double(gx), y: (Double(cy) + 0.5) / Double(gy)),
            dx: vx, dy: vy, weight: cnt[idx] / max(maxC, 1)))
    }
    return arrows
}

private struct StopPinsLayer: View {
    let stops: [StopPoint]
    var body: some View {
        GeometryReader { geo in
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, s in
                VStack(spacing: 1) {
                    Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(.orange)
                        .background(Circle().fill(.white).padding(3))
                    Text("\(i + 1) · \(s.dwellText)").font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .position(x: s.point.x * geo.size.width, y: s.point.y * geo.size.height)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct PathSummary: View {
    let trajectories: [[CGPoint]]
    let flow: [FlowArrow]
    var background: NSImage? = nil
    /// Lintasan padat dari engine; kalau ada, ini yang dirangkai.
    var densePaths: [[CGPoint]] = []
    var widthM: Double = 10
    var heightM: Double = 7.5

    /// Seluruh jejak biru dirangkai jadi satu garis. Tidak ada yang disaring:
    /// jejak sependek apa pun ikut, dan batas lantai tidak dipakai.
    private var linkedRoutes: [[CGPoint]] {
        // Sumbernya semua yang digambar biru, ditambah lintasan padat dari engine.
        let source = (trajectories + densePaths).flatMap { $0 }
        let pieces = MainRoute.loopAroundTables(points: source, widthM: widthM,
                                               heightM: heightM, floorplan: background)
                   + MainRoute.ringsAroundTables(points: source, widthM: widthM,
                                                 heightM: heightM, floorplan: background)
        // garis yang saling menimpa disatukan: yang tertimpa dibuang bagiannya
        // Penggeseran ke tepi lantai (MainRoute.snapToFloor) sengaja tidak
        // dipakai: hasilnya kurang rapi dibanding versi ini.
        return MainRoute.dedupe(pieces, widthM: widthM, heightM: heightM,
                                minLengthM: 1.5)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                    Color.black.opacity(0.18).allowsHitTesting(false)
                } else {
                    Color(hex: 0x0F1524)
                }
                // Heatmap garis: semua lintasan, garis tipis transparan -> menumpuk
                // jadi terang. Tiap lintasan dihaluskan dulu supaya yang menumpuk
                // bentuk jalurnya, bukan getaran deteksi tiap langkah. Digambar dua
                // lapis: lapis lebar yang samar untuk sebaran, lapis tipis yang
                // lebih pekat untuk intinya -> tumpukannya jadi lebih terbaca.
                Canvas { ctx, size in
                    for raw in trajectories {
                        let t = Foodcourt_smoothPath(raw, sigma: 3)
                        var path = Path(); var started = false
                        for i in 1..<t.count {
                            let a = t[i - 1], b = t[i]
                            if hypot(b.x - a.x, b.y - a.y) > 0.15 { started = false; continue }
                            let pa = CGPoint(x: a.x * size.width, y: a.y * size.height)
                            let pb = CGPoint(x: b.x * size.width, y: b.y * size.height)
                            if !started { path.move(to: pa); started = true }
                            path.addLine(to: pb)
                        }
                        // Satu lapis lebar dan pudar saja: perannya latar bukti,
                        // bukan gambar utama. Jalur biru tebal yang jadi fokus.
                        ctx.stroke(path, with: .color(.cyan.opacity(0.055)),
                                   style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    }
                }
                .blur(radius: 1)
                // Semua jejak biru itu dirangkai jadi SATU garis: mulai dari yang
                // terpanjang, terus disambung ke jejak terdekat yang searah, dari
                // kedua ujungnya. Yang samar pun ikut — tidak ada yang disaring.
                Canvas { ctx, size in
                    for route in linkedRoutes where route.count > 3 {
                        var path = Path()
                        path.move(to: CGPoint(x: route[0].x * size.width,
                                              y: route[0].y * size.height))
                        for p in route.dropFirst() {
                            path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                        }
                        ctx.stroke(path, with: .color(.white.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        ctx.stroke(path, with: .color(Color(hex: 0x1C7ED6)),
                                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

                        // Panah arah. Arahnya TIDAK dikarang: garis cuma tahu
                        // bentuk, bukan arah jalan. Tiap panah menoleh ke arus
                        // orang di sekitarnya (medan panah oranye); kalau di situ
                        // tidak ada arus yang jelas, panahnya tidak digambar.
                        let every = max(6, route.count / 8)
                        for i in stride(from: every, to: route.count - 2, by: every) {
                            let a = route[max(0, i - 3)], b = route[min(route.count - 1, i + 3)]
                            var tx = Double(b.x - a.x), ty = Double(b.y - a.y)
                            let tm = hypot(tx, ty)
                            guard tm > 1e-9 else { continue }
                            tx /= tm; ty /= tm

                            let p = route[i]
                            var sx = 0.0, sy = 0.0
                            for f in flow {
                                let d = hypot(Double(f.at.x - p.x), Double(f.at.y - p.y))
                                guard d <= 0.08 else { continue }
                                sx += f.dx * f.weight; sy += f.dy * f.weight
                            }
                            let sm = hypot(sx, sy)
                            guard sm > 1e-6 else { continue }
                            let searah = (sx / sm) * tx + (sy / sm) * ty
                            guard abs(searah) >= 0.30 else { continue }
                            if searah < 0 { tx = -tx; ty = -ty }

                            let tip = CGPoint(x: p.x * size.width, y: p.y * size.height)
                            let ang = atan2(ty * Double(size.height), tx * Double(size.width))
                            let wing = Double.pi / 6, len = 11.0
                            var head = Path()
                            head.move(to: CGPoint(x: Double(tip.x) + cos(ang) * len * 0.5,
                                                  y: Double(tip.y) + sin(ang) * len * 0.5))
                            head.addLine(to: CGPoint(x: Double(tip.x) - cos(ang - wing) * len * 0.6,
                                                     y: Double(tip.y) - sin(ang - wing) * len * 0.6))
                            head.addLine(to: CGPoint(x: Double(tip.x) - cos(ang + wing) * len * 0.6,
                                                     y: Double(tip.y) - sin(ang + wing) * len * 0.6))
                            head.closeSubpath()
                            ctx.stroke(head, with: .color(.white.opacity(0.9)),
                                       style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                            ctx.fill(head, with: .color(Color(hex: 0x0B4F8A)))
                        }
                    }
                }
                // Medan aliran: panah arah rata-rata orang bergerak per area.
                // Versi garis aliran (FlowStreams) sudah dicoba dan ditolak:
                // panahnya terlalu kecil dan terlalu rapat.
                Canvas { ctx, size in
                    for a in flow {
                        let base = CGPoint(x: a.at.x * size.width, y: a.at.y * size.height)
                        let ang = atan2(a.dy, a.dx)
                        // Semua panah yang lolos saringan kekompakan sama-sama
                        // layak dipercaya, jadi tebal dan pekatnya dibuat sama.
                        // Ramai-sepinya cuma diwakili sedikit selisih panjang.
                        let len = (0.040 + 0.022 * a.weight) * size.width
                        let tip = CGPoint(x: base.x + cos(ang) * len, y: base.y + sin(ang) * len)
                        let col = Color(hue: 0.09, saturation: 0.85, brightness: 1.0)
                            .opacity(0.85)
                        var line = Path(); line.move(to: base); line.addLine(to: tip)
                        ctx.stroke(line, with: .color(col),
                                   style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        let ah = 6.5
                        let l = CGPoint(x: tip.x - cos(ang - .pi / 6) * ah, y: tip.y - sin(ang - .pi / 6) * ah)
                        let r = CGPoint(x: tip.x - cos(ang + .pi / 6) * ah, y: tip.y - sin(ang + .pi / 6) * ah)
                        var head = Path(); head.move(to: tip); head.addLine(to: l); head.addLine(to: r); head.closeSubpath()
                        ctx.fill(head, with: .color(col))
                    }
                }
            }
        }
    }
}

/// Rata-rata bergerak berbobot Gauss: menghilangkan getaran deteksi tiap langkah
/// tanpa memindahkan jalurnya.
func Foodcourt_smoothPath(_ pts: [CGPoint], sigma: Double = 2.4) -> [CGPoint] {
    guard pts.count > 4, sigma > 0 else { return pts }
    let radius = max(1, Int(sigma * 2.5))
    var kernel: [Double] = []
    for i in -radius...radius { kernel.append(exp(-Double(i * i) / (2 * sigma * sigma))) }
    let norm = kernel.reduce(0, +)
    return pts.indices.map { index in
        var sx = 0.0, sy = 0.0
        for (k, weight) in kernel.enumerated() {
            let j = min(pts.count - 1, max(0, index + k - radius))
            sx += Double(pts[j].x) * weight
            sy += Double(pts[j].y) * weight
        }
        return CGPoint(x: sx / norm, y: sy / norm)
    }
}

private struct PathTab: View {
    let paths: [PathTrace]
    let trajectories: [[CGPoint]]
    let flow: [FlowArrow]
    let stops: [StopPoint]
    var background: NSImage? = nil
    var widthM: Double = 10
    var heightM: Double = 7.5
    @State private var mode = 0   // 0 = detail, 1 = ringkasan

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if mode == 0 {
                    PathContent(paths: paths, background: background)
                } else {
                    PathSummary(trajectories: trajectories, flow: flow, background: background,
                                densePaths: paths.map { $0.points },
                                widthM: widthM, heightM: heightM)
                }
            }
            .overlay(StopPinsLayer(stops: stops))

            Picker("", selection: $mode) {
                Text("Detail").tag(0)
                Text("Summary").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(Space.s)
        }
    }
}

// MARK: - Editor Zona (user gambar/geser/resize/rename)

/// Metrik satu zona dari observasi ber-track: orang unik, rata-rata durasi (detik), jumlah observasi.
func Foodcourt_zoneMetrics(_ rect: CGRect, _ obs: [TrackObservation]) -> (people: Int, avgDurSec: Double, count: Int) {
    let inside = obs.filter { rect.contains($0.point) }
    if inside.isEmpty { return (0, 0, 0) }
    let byTrack = Dictionary(grouping: inside, by: { $0.trackId })
    var durs: [Double] = []
    for (_, o) in byTrack {
        let ts = o.map { $0.t }
        if let lo = ts.min(), let hi = ts.max() { durs.append(hi - lo) }
    }
    let avg = durs.isEmpty ? 0 : durs.reduce(0, +) / Double(durs.count)
    return (byTrack.count, avg, inside.count)
}

private struct ZonaEditor: View {
    let session: AnalysisSession
    let observations: [TrackObservation]
    var background: NSImage? = nil

    @State private var selected: UUID? = nil
    @State private var dragStart: [UUID: CGRect] = [:]

    private let palette: [UInt] = Theme.palette

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                // background
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                    Color.white.opacity(0.06).allowsHitTesting(false)
                } else {
                    Theme.canvasBackground
                }

                // area kosong -> deselect
                Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }

                ForEach(session.customZones) { zone in
                    zoneView(zone, W: W, H: H)
                }

                controls
            }
            .coordinateSpace(name: "floor")
        }
    }

    private func idx(_ id: UUID) -> Int? { session.customZones.firstIndex { $0.id == id } }

    private func zoneView(_ zone: CustomZone, W: CGFloat, H: CGFloat) -> some View {
        let color = Color(hex: zone.colorHex)
        let sr = CGRect(x: zone.rect.minX * W, y: zone.rect.minY * H,
                        width: zone.rect.width * W, height: zone.rect.height * H)
        let m = Foodcourt_zoneMetrics(zone.rect, observations)
        let isSel = selected == zone.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: isSel ? 3 : 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.name).font(.caption.bold()).foregroundStyle(color).lineLimit(1)
                Text("\(m.people) people").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                Text("~\(timecode(m.avgDurSec))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(5)

            if isSel {
                Circle().fill(color).frame(width: 16, height: 16)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                    .position(x: sr.width, y: sr.height)
                    .highPriorityGesture(resizeDrag(zone, W: W, H: H))
            }
        }
        .frame(width: max(12, sr.width), height: max(12, sr.height))
        .position(x: sr.midX, y: sr.midY)
        .onTapGesture { selected = zone.id }
        .gesture(moveDrag(zone, W: W, H: H))
    }

    private func moveDrag(_ zone: CustomZone, W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("floor"))
            .onChanged { v in
                guard let i = idx(zone.id) else { return }
                let start = dragStart[zone.id] ?? session.customZones[i].rect
                if dragStart[zone.id] == nil { dragStart[zone.id] = start; selected = zone.id }
                let dx = v.translation.width / W, dy = v.translation.height / H
                var r = start
                r.origin.x = min(max(0, start.minX + dx), 1 - start.width)
                r.origin.y = min(max(0, start.minY + dy), 1 - start.height)
                session.customZones[i].rect = r
            }
            .onEnded { _ in dragStart[zone.id] = nil }
    }

    private func resizeDrag(_ zone: CustomZone, W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("floor"))
            .onChanged { v in
                guard let i = idx(zone.id) else { return }
                let start = dragStart[zone.id] ?? session.customZones[i].rect
                if dragStart[zone.id] == nil { dragStart[zone.id] = start }
                let dw = v.translation.width / W, dh = v.translation.height / H
                var r = start
                r.size.width = min(max(0.04, start.width + dw), 1 - start.minX)
                r.size.height = min(max(0.04, start.height + dh), 1 - start.minY)
                session.customZones[i].rect = r
            }
            .onEnded { _ in dragStart[zone.id] = nil }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Button { addZone() } label: {
                Label("Add Zone", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.accentFill, in: Capsule())
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.plain)

            if let sid = selected, session.customZones.contains(where: { $0.id == sid }) {
                HStack(spacing: 6) {
                    TextField("Zone name", text: Binding(
                        get: { session.customZones.first(where: { $0.id == sid })?.name ?? "" },
                        set: { newVal in
                            if let i = session.customZones.firstIndex(where: { $0.id == sid }) {
                                session.customZones[i].name = newVal
                            }
                        }))
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                    Button(role: .destructive) {
                        selected = nil
                        session.customZones.removeAll { $0.id == sid }
                    } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    .buttonStyle(.borderless)
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(Space.s)
    }

    private func addZone() {
        let n = session.customZones.count
        let letter = Character(UnicodeScalar(65 + (n % 26))!)
        let z = CustomZone(name: "Zone \(letter)",
                           rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           colorHex: palette[n % palette.count])
        session.customZones.append(z)
        selected = z.id
    }
}

// MARK: - Baris zona (dengan warna)

private struct ZoneRow: View {
    let zone: ZoneRank
    private var color: Color { Color(hex: zone.colorHex) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: 14, height: 14)
                Text("\(zone.rank).").font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                Text(zone.name).font(.callout)
                Spacer()
                Text("\(zone.visits)").font(.callout.monospacedDigit().weight(.medium))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: geo.size.width * zone.share)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Peta zona

private struct ZoneMapView: View {
    let zones: [ZoneRank]
    var background: NSImage? = nil
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack {
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                    Color.white.opacity(0.08).allowsHitTesting(false)
                } else {
                    Theme.canvasBackground

                    // grid halus sebagai konteks lantai
                    Canvas { ctx, size in
                        var grid = Path()
                        let cols = 10, rows = 6
                        for c in 0...cols { let x = size.width * CGFloat(c)/CGFloat(cols)
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                        for r in 0...rows { let y = size.height * CGFloat(r)/CGFloat(rows)
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                        ctx.stroke(grid, with: .color(Theme.canvasGrid), lineWidth: 1)
                    }
                }

                ForEach(zones) { zone in
                    let color = Color(hex: zone.colorHex)
                    let r = CGRect(x: zone.rect.minX * W, y: zone.rect.minY * H,
                                   width: zone.rect.width * W, height: zone.rect.height * H)
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .fill(color.opacity(0.20))
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .strokeBorder(color, lineWidth: 1.5)
                        VStack(spacing: 1) {
                            Text(zone.code)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(color)
                            Text("\(Int((zone.share * 100).rounded()))%")
                                .font(.caption.weight(.semibold)).foregroundStyle(color)
                            Text("\(zone.visits)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                }
            }
        }
    }
}

// MARK: - Konten video: bounding box

private struct BoundingBoxContent: View {
    @State private var phase = false
    private let boxes: [(id: Int, rect: CGRect)] = [
        (7,  CGRect(x: 0.18, y: 0.30, width: 0.10, height: 0.34)),
        (12, CGRect(x: 0.42, y: 0.26, width: 0.11, height: 0.40)),
        (23, CGRect(x: 0.64, y: 0.34, width: 0.09, height: 0.30)),
        (31, CGRect(x: 0.80, y: 0.42, width: 0.08, height: 0.26))
    ]
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x232733), Color(hex: 0x12151D)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(boxes, id: \.id) { box in
                    let r = CGRect(x: box.rect.minX * geo.size.width, y: box.rect.minY * geo.size.height,
                                   width: box.rect.width * geo.size.width, height: box.rect.height * geo.size.height)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                        Text("ID \(box.id)").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accentFill).foregroundStyle(Theme.onAccent).offset(y: -14)
                        Circle().fill(.orange).frame(width: 5, height: 5)
                            .offset(x: r.width / 2 - 2.5, y: r.height - 2.5)
                    }
                    .position(x: r.midX, y: r.midY)
                    .opacity(phase ? 1 : 0.6)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

// MARK: - Konten video: path simulation

private struct PathContent: View {
    let paths: [PathTrace]
    var background: NSImage? = nil

    private var span: (lo: Double, hi: Double) {
        let all = paths.flatMap { $0.times }
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return (0, 1) }
        return (lo, hi)
    }

    var body: some View {
        let (lo, hi) = span
        GeometryReader { geo in
            ZStack {
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                } else {
                    Theme.canvasBackground
                    Canvas { ctx, size in
                        var grid = Path()
                        let cols = 10, rows = 6
                        for c in 0...cols { let x = size.width * CGFloat(c)/CGFloat(cols)
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                        for r in 0...rows { let y = size.height * CGFloat(r)/CGFloat(rows)
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                        ctx.stroke(grid, with: .color(Theme.canvasGrid), lineWidth: 1)
                    }
                }

                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        let loop = 10.0   // detik nyata untuk satu putaran
                        let phase = tl.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: loop) / loop
                        let cursor = lo + phase * (hi - lo)
                        draw(ctx, size, cursor: cursor, phase: phase)
                    }
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, cursor: Double, phase: Double) {
        for trace in paths {
            let n = trace.points.count
            guard n >= 2 else { continue }
            // berapa titik yang sudah "terlihat" sampai cursor
            let upto: Int
            if trace.times.count == n {
                upto = max(1, trace.times.filter { $0 <= cursor }.count)
            } else {
                upto = max(1, Int(phase * Double(n)))
            }
            let vis = Array(trace.points.prefix(upto))
            let color = Color(hue: trace.hue, saturation: 0.85, brightness: 0.95)

            // jejak (diputus di lompatan besar)
            var g = Path()
            var started = false
            for (a, b) in zip(vis, vis.dropFirst()) {
                if hypot(b.x - a.x, b.y - a.y) > 0.15 { started = false; continue }
                let pa = CGPoint(x: a.x * size.width, y: a.y * size.height)
                let pb = CGPoint(x: b.x * size.width, y: b.y * size.height)
                if !started { g.move(to: pa); started = true }
                g.addLine(to: pb)
            }
            ctx.stroke(g, with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            // kepala (titik bergerak)
            if let head = vis.last {
                let p = CGPoint(x: head.x * size.width, y: head.y * size.height)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(color))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                           with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Heatmap + legend

private struct HeatmapLegend: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: Space.s) {
                    Text("Low").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    LinearGradient(stops: Theme.heatStops, startPoint: .leading, endPoint: .trailing)
                        .frame(width: 80, height: 8).clipShape(Capsule())
                    Text("High").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(.black.opacity(0.3), in: Capsule())
            }
        }
        .padding(Space.m)
    }
}

private struct HeatmapView: View {
    let blobs: [HeatBlob]
    var background: NSImage? = nil
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                    Color.black.opacity(0.25).allowsHitTesting(false)
                } else {
                    Color(hex: 0x0F1524)
                }
                Canvas { ctx, size in
                    ctx.addFilter(.blur(radius: 18))
                    ctx.drawLayer { layer in
                        for blob in blobs {
                            let r = blob.radius * size.width
                            let center = CGPoint(x: blob.x * size.width, y: blob.y * size.height)
                            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                            let shading = GraphicsContext.Shading.radialGradient(
                                Gradient(stops: [
                                    .init(color: heatColor(blob.intensity).opacity(0.9), location: 0),
                                    .init(color: heatColor(blob.intensity).opacity(0.0), location: 1)
                                ]),
                                center: center, startRadius: 0, endRadius: r)
                            layer.fill(Path(ellipseIn: rect), with: shading)
                        }
                    }
                }
            }
        }
    }
    private func heatColor(_ i: Double) -> Color {
        switch i {
        case ..<0.4:  return Color(hex: 0x3B82F6)
        case ..<0.65: return Color(hex: 0x22C55E)
        case ..<0.85: return Color(hex: 0xFACC15)
        default:      return Color(hex: 0xEF4444)
        }
    }
}

// MARK: - Chrome video (play + scrubber)

private struct VideoChrome: View {
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35)).frame(width: 62, height: 62)
                .overlay(Image(systemName: "play.fill").font(.title2).foregroundStyle(.white))
            VStack {
                Spacer()
                HStack(spacing: Space.s) {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                    Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * 0.32) }
                        }
                    Text("0:04 / 0:12").font(.caption2.monospacedDigit()).foregroundStyle(.white)
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(.black.opacity(0.28))
            }
        }
    }
}

#Preview {
    ResultsView()
        .environment(AnalysisSession())
        .frame(width: 1200, height: 900)
}
