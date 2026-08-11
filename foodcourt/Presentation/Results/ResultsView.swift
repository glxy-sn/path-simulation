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
                if identityQuality != nil { identityQualityCard }
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
            PrimaryButton(title: "Export Laporan", systemImage: "square.and.arrow.up") {}
        }
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

    private var identityQualityCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kualitas Identitas").font(.headline)
                    Text("Confidence asosiasi global yang sama dipakai pada video dan trajectory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = session.result?.fusionDiagnosticsURL {
                    Button("Buka Diagnostics", systemImage: "doc.text.magnifyingglass") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let quality = identityQuality {
                HStack(spacing: Space.s) {
                    identityQualityTile("High", quality.highConfidence, .green, "≥ 0,80")
                    identityQualityTile("Medium", quality.mediumConfidence, .orange, "0,70–0,79")
                    identityQualityTile("Low", quality.lowConfidence, .red, "< 0,70")
                    identityQualityTile("Single Camera", quality.singleCamera, .secondary, "Belum lintas kamera")
                }
                Divider()
                Text("\(quality.globalIDs) global ID · \(quality.localStitches) local stitch · \(quality.overlapMerges) overlap merge · \(quality.handoverMerges) handover merge · \(quality.unmatchedTracklets) unmatched · \(quality.filteredTracklets) filtered")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !quality.calibrationWarnings.isEmpty {
                    Label("\(quality.calibrationWarnings.count) warning kalibrasi tercatat", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .card()
    }

    private func identityQualityTile(_ title: String, _ count: Int, _ color: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.title3.monospacedDigit().bold()).foregroundStyle(color)
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
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
                    ZoneMapView(zones: zones, background: floorMapImage)
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
                ForEach(zones) { zone in ZoneRow(zone: zone) }
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
