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
    case boundingBox = "Deteksi"
    case path = "Path Simulation"
    case heatmap = "Heatmap"
    case zona = "Zona"
    var id: String { rawValue }
}

struct ResultsView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AnalysisSession.self) private var session
    @Environment(AppRouter.self) private var router
    @State private var visual: ResultVisual = .boundingBox
    @State private var showExport = false

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
    private var observations: [CGPoint] { session.result?.observations ?? [] }

    private func obsCount(_ rect: CGRect) -> Int {
        observations.reduce(0) { $0 + (rect.contains($1) ? 1 : 0) }
    }

    private var rankedCustomZones: [(zone: CustomZone, count: Int)] {
        session.customZones
            .map { (zone: $0, count: obsCount($0.rect)) }
            .sorted { $0.count > $1.count }
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
    }

    private var header: some View {
        HStack(alignment: .center) {
            SectionHeader(title: "Hasil Analisis", subtitle: subtitle)
            GhostButton(title: "Analisis Baru", systemImage: "plus") {
                session.reset()
                router.startNew()
            }
            PrimaryButton(title: "Export Laporan", systemImage: "square.and.arrow.up") {
                showExport = true
            }
            .disabled(session.result == nil)
        }
        .confirmationDialog("Export Laporan", isPresented: $showExport, titleVisibility: .visible) {
            Button("JSON — lengkap (untuk analisis / LLM)") { exportJSON() }
            Button("CSV — ringkasan (untuk Excel)") { exportCSV() }
            Button("Batal", role: .cancel) {}
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

    private func exportJSON() {
        guard let r = session.result else { return }
        var dict: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "venue": ["name": session.venueName, "type": session.venueType.rawValue,
                      "widthM": session.venueWidthM, "heightM": session.venueHeightM],
            "window": ["startSec": session.trimStartSec,
                       "durationSec": max(0, session.trimEndSec - session.trimStartSec)],
            "summary": ["totalVisitors": r.summary.totalVisitors,
                        "avgDwellSeconds": r.summary.avgDwellSeconds,
                        "peakOccupancy": r.summary.peakOccupancy,
                        "captureRate": r.summary.captureRate],
            "zones": r.zones.map { ["code": $0.code, "visits": $0.visits, "share": $0.share,
                                    "rect": ["x": $0.rect.minX, "y": $0.rect.minY,
                                             "w": $0.rect.width, "h": $0.rect.height]] },
            "stopPoints": r.stops.map { ["name": $0.name, "dwellSeconds": $0.dwellSeconds] },
            "occupancy": r.occupancy.map { ["minute": $0.minute, "count": $0.count] },
        ]
        dict["paths"] = r.paths.enumerated().map { (i, p) -> [String: Any] in
            var pts: [[String: Any]] = []
            for (idx, pt) in p.points.enumerated() {
                let t = idx < p.times.count ? p.times[idx] : 0
                pts.append(["x": Double(pt.x), "y": Double(pt.y), "t": t])
            }
            return ["id": i, "hue": p.hue, "points": pts]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        save(name: defaultName() + ".json", type: .json, data: data)
    }

    private func exportCSV() {
        guard let r = session.result else { return }
        var s = "Laporan Analisis Food Court\n"
        s += "Venue,\(session.venueName)\n"
        s += "Dimensi (m),\(session.venueWidthM) x \(session.venueHeightM)\n\n"
        s += "Metrik,Nilai\n"
        s += "Total Pengunjung,\(r.summary.totalVisitors)\n"
        s += "Rata-rata Dwell (detik),\(r.summary.avgDwellSeconds)\n"
        s += "Puncak Okupansi,\(r.summary.peakOccupancy)\n"
        s += "Capture Rate,\(r.summary.captureRate)\n\n"
        s += "Zona,Visits,Share\n"
        for z in r.zones { s += "\(z.code),\(z.visits),\(z.share)\n" }
        s += "\nStop Point,Dwell (detik)\n"
        for st in r.stops { s += "\(st.name),\(st.dwellSeconds)\n" }
        s += "\nMenit,Okupansi\n"
        for o in r.occupancy { s += "\(o.minute),\(o.count)\n" }
        guard let data = s.data(using: .utf8) else { return }
        save(name: defaultName() + ".csv", type: .commaSeparatedText, data: data)
    }

    private var subtitle: String {
        if hasResult {
            let name = session.venueName.isEmpty ? "Venue" : session.venueName
            let dur = timecode(session.trimEndSec - session.trimStartSec)
            return "\(name) · \(session.cameras.count) kamera · durasi \(dur)"
        }
        return "Contoh data — jalankan analisis untuk hasil nyata."
    }

    private var metrics: some View {
        HStack(spacing: Space.m * scale) {
            MetricTile(title: "Total Pengunjung", value: "\(summary.totalVisitors)", systemImage: "person.2.fill")
            MetricTile(title: "Rata-rata Dwell", value: summary.avgDwellText, systemImage: "clock.fill", tint: .orange)
            MetricTile(title: "Puncak Okupansi", value: "\(summary.peakOccupancy)", systemImage: "chart.line.uptrend.xyaxis", tint: .pink)
            MetricTile(title: "Capture Rate", value: summary.captureRateText, systemImage: "arrow.down.right.circle.fill", tint: .green)
        }
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Visualisasi").font(.headline)
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
                    PathContent(paths: paths, background: floorMapImage)
                        .aspectRatio(venueAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                case .heatmap:
                    HeatmapView(blobs: blobs, background: floorMapImage)
                        .aspectRatio(venueAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottomTrailing) { HeatmapLegend().padding(Space.s) }
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
                ? "Video deteksi + ID global antar-kamera (grid + BEV bila multi-kamera)."
                : "Contoh — jalankan analisis untuk video nyata."
        case .path:    return "Simulasi jalur pergerakan pengunjung di bidang lantai."
        case .heatmap: return "Kepadatan pergerakan diproyeksikan ke denah lantai."
        case .zona:    return "Pembagian zona di denah. Warna sama dengan daftar ranking di bawah."
        }
    }

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Zona Paling Sering Dilewati").font(.headline)
                if session.customZones.isEmpty {
                    Text("Buka tab Zona untuk menggambar zona sendiri (mis. area kasir, tempat duduk).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(zones) { zone in ZoneRow(zone: zone) }
                } else {
                    ForEach(rankedCustomZones, id: \.zone.id) { item in
                        HStack(spacing: Space.s) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: item.zone.colorHex))
                                .frame(width: 12, height: 12)
                            Text(item.zone.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(item.count)").font(.callout.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Stop Point Terlama").font(.headline)
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
            Text("Okupansi dari Waktu ke Waktu").font(.headline)
            Chart(occupancy) { point in
                AreaMark(x: .value("Menit", point.minute), y: .value("Orang", point.count))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Menit", point.minute), y: .value("Orang", point.count))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxisLabel("menit ke-")
            .chartYAxisLabel("orang")
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

// MARK: - Editor Zona (user gambar/geser/resize/rename)

private struct ZonaEditor: View {
    let session: AnalysisSession
    let observations: [CGPoint]
    var background: NSImage? = nil

    @State private var selected: UUID? = nil
    @State private var dragStart: [UUID: CGRect] = [:]

    private let palette: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                // background
                if let background {
                    Image(nsImage: background).resizable().allowsHitTesting(false)
                    Color.white.opacity(0.06).allowsHitTesting(false)
                } else {
                    Color(hex: 0xF7F8FA)
                }
                // titik observasi (samar)
                Canvas { ctx, size in
                    for p in observations {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x * size.width - 1.2, y: p.y * size.height - 1.2,
                                                        width: 2.4, height: 2.4)),
                                 with: .color(.orange.opacity(0.30)))
                    }
                }
                .allowsHitTesting(false)

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
        let count = observations.reduce(0) { $0 + (zone.rect.contains($1) ? 1 : 0) }
        let isSel = selected == zone.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: isSel ? 3 : 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.name).font(.caption.bold()).foregroundStyle(color).lineLimit(1)
                Text("\(count)").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
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
                Label("Zona", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if let sid = selected, let i = idx(sid) {
                HStack(spacing: 6) {
                    TextField("Nama zona", text: Binding(
                        get: { session.customZones[i].name },
                        set: { session.customZones[i].name = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                    Button(role: .destructive) {
                        session.customZones.removeAll { $0.id == sid }
                        selected = nil
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
        let z = CustomZone(name: "Zona \(letter)",
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
                    Color(hex: 0xF7F8FA)

                    // grid halus sebagai konteks lantai
                    Canvas { ctx, size in
                        var grid = Path()
                        let cols = 10, rows = 6
                        for c in 0...cols { let x = size.width * CGFloat(c)/CGFloat(cols)
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                        for r in 0...rows { let y = size.height * CGFloat(r)/CGFloat(rows)
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                        ctx.stroke(grid, with: .color(Color(hex: 0x1E293B, alpha: 0.07)), lineWidth: 1)
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
                            .background(Theme.accent).foregroundStyle(.white).offset(y: -14)
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
                    Color(hex: 0xF7F8FA)
                    Canvas { ctx, size in
                        var grid = Path()
                        let cols = 10, rows = 6
                        for c in 0...cols { let x = size.width * CGFloat(c)/CGFloat(cols)
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                        for r in 0...rows { let y = size.height * CGFloat(r)/CGFloat(rows)
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                        ctx.stroke(grid, with: .color(Color(hex: 0x1E293B, alpha: 0.08)), lineWidth: 1)
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
                    Text("Rendah").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    LinearGradient(stops: Theme.heatStops, startPoint: .leading, endPoint: .trailing)
                        .frame(width: 80, height: 8).clipShape(Capsule())
                    Text("Tinggi").font(.caption2).foregroundStyle(.white.opacity(0.8))
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
