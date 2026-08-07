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

    /// Floor map untuk background Zona (kalau user pakai floor plan, bukan canvas).
    private var floorMapImage: NSImage? {
        guard !session.usesScaledCanvas, let url = session.floorPlanURL else { return nil }
        return NSImage(contentsOf: url)
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

            ZStack {
                switch visual {
                case .boundingBox:
                    if let url = boundingVideoURL { FileVideoPlayer(url: url) }
                    else { BoundingBoxContent(); VideoChrome() }
                case .path:
                    if let url = pathVideoURL { FileVideoPlayer(url: url) }
                    else { PathContent(paths: SampleResult.paths); VideoChrome() }
                case .heatmap:
                    if let url = heatmapURL { FileImage(url: url) }
                    else { HeatmapView(blobs: SampleResult.blobs); HeatmapLegend() }
                case .zona:
                    ZoneMapView(zones: zones, background: floorMapImage)
                }
            }
            .frame(height: min(400, max(300, 360 * scale)))
            .frame(maxWidth: .infinity)
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
                    Image(nsImage: background).resizable().scaledToFill()
                        .frame(width: W, height: H).clipped()
                    Color.white.opacity(0.08)
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
                        VStack(spacing: 2) {
                            Text(zone.code)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(color)
                            Text("\(zone.visits)")
                                .font(.caption.monospacedDigit())
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
    var body: some View {
        GeometryReader { geo in
            ZStack {
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
                ForEach(paths) { trace in
                    let color = Color(hue: trace.hue, saturation: 0.75, brightness: 0.9)
                    Path { p in
                        let pts = trace.points.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
                        p.addLines(pts)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let s = trace.points.first {
                        Circle().fill(.green).frame(width: 9, height: 9)
                            .position(x: s.x * geo.size.width, y: s.y * geo.size.height)
                    }
                    if let e = trace.points.last {
                        Circle().fill(.red).frame(width: 9, height: 9)
                            .position(x: e.x * geo.size.width, y: e.y * geo.size.height)
                    }
                }
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
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0F1524)))
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
