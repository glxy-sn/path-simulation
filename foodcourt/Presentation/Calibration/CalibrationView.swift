//
//  CalibrationView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CalibrationView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session

    @State private var selected = 0
    @State private var planeSource: PlaneSource = .canvas
    @State private var floorPlanImage: NSImage? = nil
    @State private var floorPlanName: String? = nil

    private var idx: Int { min(max(0, selected), max(0, session.cameras.count - 1)) }

    var body: some View {
        if session.cameras.isEmpty {
            emptyState
        } else {
            content
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "camera.metering.none").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Belum ada kamera").font(.headline)
            Text("Import video dulu di langkah sebelumnya.").font(.callout).foregroundStyle(.secondary)
            GhostButton(title: "Ke Import", systemImage: "chevron.left") { router.back() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m * scale) {
                SectionHeader(
                    title: "Kalibrasi",
                    subtitle: "Cocokkan 4 titik yang sama antara frame CCTV dan denah lantai."
                )
                // Titiknya benar-benar tersimpan dan ikut terkirim ke engine,
                // tapi pipeline belum membacanya. Tanpa keterangan ini, orang
                // menggambar 4 titik per kamera dengan teliti dan mengira
                // hasilnya berubah — padahal sama persis.
                InfoNote(text: "Titik yang kamu gambar disimpan dan dikirim ke engine, "
                         + "tapi pipeline BELUM memakainya — hasil analisis belum berubah "
                         + "karenanya. Proyeksi bidang lantai masih dikerjakan.",
                         systemImage: "exclamationmark.triangle")
                cameraSelector
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.m)

            HStack(alignment: .top, spacing: Space.l * scale) {
                canvases.frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector.relativeWidth(0.24)
            }
            .spad(Space.xl, [.horizontal])
            .padding(.bottom, Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WizardFooter(onBack: { router.back() }) {
                PrimaryButton(title: "Lanjut ke Proses",
                              systemImage: "arrow.right",
                              enabled: session.cameras[idx].isCalibrated) {
                    router.next()
                }
            }
        }
    }

    private var cameraSelector: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(session.cameras.enumerated()), id: \.element.id) { i, cam in
                let isSel = i == idx
                Button { selected = i } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: cam.isCalibrated ? "checkmark.circle.fill" : "camera")
                            .foregroundStyle(cam.isCalibrated ? Color.green : (isSel ? Color.white : Color.secondary))
                        Text(cam.label).foregroundStyle(isSel ? Color.white : Color.primary)
                    }
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .background(isSel ? Theme.accent : Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var canvases: some View {
        let i = idx
        return HStack(spacing: Space.m * scale) {
            InteractiveCanvas(
                title: "Frame CCTV — \(session.cameras[i].label)",
                subtitle: "Klik untuk taruh titik · klik titik untuk hapus",
                kind: .frame,
                planeImage: nil,
                needsUpload: false,
                points: session.cameras[i].imagePoints,
                accent: Theme.accent,
                onAdd: { p in
                    if session.cameras[i].imagePoints.count < 4 {
                        session.cameras[i].imagePoints.append(NormPoint(x: p.x, y: p.y))
                    }
                },
                onDeleteIndex: { j in
                    if session.cameras[i].imagePoints.indices.contains(j) {
                        session.cameras[i].imagePoints.remove(at: j)
                    }
                },
                onUpload: nil
            )
            InteractiveCanvas(
                title: planeSource == .canvas ? "Canvas Berskala" : "Floor Plan",
                subtitle: "Klik titik yang bersesuaian",
                kind: .plane,
                planeImage: floorPlanImage,
                needsUpload: planeSource == .floorplan && floorPlanImage == nil,
                points: session.cameras[i].planePoints,
                accent: .orange,
                onAdd: { p in
                    if session.cameras[i].planePoints.count < 4 {
                        session.cameras[i].planePoints.append(NormPoint(x: p.x, y: p.y))
                    }
                },
                onDeleteIndex: { j in
                    if session.cameras[i].planePoints.indices.contains(j) {
                        session.cameras[i].planePoints.remove(at: j)
                    }
                },
                onUpload: { uploadFloorPlan() }
            )
        }
    }

    private var inspector: some View {
        let i = idx
        return VStack(alignment: .leading, spacing: Space.m * scale) {
            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Sumber Denah")
                Picker("", selection: $planeSource) {
                    ForEach(PlaneSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if planeSource == .floorplan {
                    GhostButton(title: floorPlanName == nil ? "Pilih File Denah" : "Ganti Denah",
                                systemImage: "photo.on.rectangle") { uploadFloorPlan() }
                    if let n = floorPlanName {
                        Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Canvas kosong berskala metrik (default).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(padding: Space.m)

            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    FieldLabel(text: "Progress")
                    Spacer()
                    Text("\(session.cameras[i].imagePoints.count)/4 · \(session.cameras[i].planePoints.count)/4")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GhostButton(title: "Reset", systemImage: "arrow.counterclockwise") {
                    session.cameras[i].imagePoints = []
                    session.cameras[i].planePoints = []
                }
            }
            .card(padding: Space.m)

            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Kamera (\(session.cameras.filter { $0.isCalibrated }.count)/\(session.cameras.count))")
                ForEach(session.cameras) { cam in
                    HStack(spacing: Space.s) {
                        Image(systemName: cam.isCalibrated ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(cam.isCalibrated ? Color.green : Color.secondary)
                        Text(cam.label).font(.callout).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .card(padding: Space.m)

            Spacer(minLength: 0)
        }
    }

    private func uploadFloorPlan() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        floorPlanName = url.lastPathComponent
        floorPlanImage = NSImage(contentsOf: url)
        planeSource = .floorplan
    }
}

// ============================================================
//  MARK: - InteractiveCanvas (zoom / pan / loupe / hapus titik)
// ============================================================

private struct InteractiveCanvas: View {
    enum Kind { case frame, plane }

    let title: String
    let subtitle: String
    let kind: Kind
    let planeImage: NSImage?
    let needsUpload: Bool
    let points: [NormPoint]
    let accent: Color
    let onAdd: (CGPoint) -> Void
    let onDeleteIndex: (Int) -> Void
    let onUpload: (() -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var loupeAt: CGPoint? = nil
    @State private var hovered: Int? = nil

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 5
    private let hitRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let W = geo.size.width, H = geo.size.height
                ZStack(alignment: .topLeading) {
                    scene(W: W, H: H)
                        .frame(width: W, height: H)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(offset)
                }
                .frame(width: W, height: H, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(placeOrPanGesture(W: W, H: H))
                .simultaneousGesture(zoomGesture(W: W, H: H))
                .overlay(alignment: .topLeading) {
                    if let l = loupeAt, !needsUpload {
                        loupe(W: W, H: H, at: l).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !needsUpload { zoomControls(W: W, H: H).padding(Space.s) }
                }
                .overlay {
                    if needsUpload { uploadPrompt }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
        }
    }

    // MARK: Scene (background + polygon + dots)

    @ViewBuilder
    private func scene(W: CGFloat, H: CGFloat) -> some View {
        ZStack {
            background

            if points.count >= 2 {
                Path { path in
                    let pts = points.map { CGPoint(x: $0.x * W, y: $0.y * H) }
                    path.addLines(pts)
                    if points.count == 4 { path.closeSubpath() }
                }
                .stroke(accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }

            ForEach(Array(points.enumerated()), id: \.element.id) { i, p in
                DotView(number: i + 1, color: accent, hovered: hovered == i)
                    .position(x: p.x * W, y: p.y * H)
                    .onHover { inside in
                        if inside { hovered = i }
                        else if hovered == i { hovered = nil }
                    }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .frame:
            FrameScene()
        case .plane:
            if let img = planeImage {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack { Color(hex: 0xF7F8FA); GridScene(cols: 8, rows: 5, color: Color(hex: 0x1E293B, alpha: 0.10)) }
            }
        }
    }

    // MARK: Gestures

    private func placeOrPanGesture(W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                loupeAt = v.location
                let moved = hypot(v.translation.width, v.translation.height)
                if moved > 6 && zoom > 1 {
                    offset = clamped(CGSize(width: baseOffset.width + v.translation.width,
                                            height: baseOffset.height + v.translation.height), W: W, H: H)
                }
            }
            .onEnded { v in
                loupeAt = nil
                let moved = hypot(v.translation.width, v.translation.height)
                if moved > 6 && zoom > 1 {
                    baseOffset = offset
                } else {
                    if let idx = nearest(to: v.location, W: W, H: H) {
                        onDeleteIndex(idx)
                    } else {
                        onAdd(normalize(v.location, W: W, H: H))
                    }
                }
            }
    }

    private func zoomGesture(W: CGFloat, H: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                zoom = min(max(baseZoom * v.magnification, minZoom), maxZoom)
                if zoom <= 1 { offset = .zero } else { offset = clamped(offset, W: W, H: H) }
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1 { baseOffset = .zero }
            }
    }

    // MARK: Zoom controls

    private func zoomControls(W: CGFloat, H: CGFloat) -> some View {
        HStack(spacing: Space.s) {
            iconButton("minus") { setZoom(zoom - 0.5, W: W, H: H) }
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40)
            iconButton("plus") { setZoom(zoom + 0.5, W: W, H: H) }
            Divider().frame(height: 14)
            iconButton("arrow.up.left.and.down.right.magnifyingglass") { resetZoom() }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func iconButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }

    private func setZoom(_ z: CGFloat, W: CGFloat, H: CGFloat) {
        zoom = min(max(z, minZoom), maxZoom)
        baseZoom = zoom
        if zoom <= 1 { offset = .zero; baseOffset = .zero }
        else { offset = clamped(offset, W: W, H: H); baseOffset = offset }
    }

    private func resetZoom() {
        zoom = 1; baseZoom = 1; offset = .zero; baseOffset = .zero
    }

    // MARK: Loupe / magnifier

    private func loupe(W: CGFloat, H: CGFloat, at l: CGPoint) -> some View {
        let n = normalize(l, W: W, H: H)
        let M = max(2.5, zoom * 1.8)
        let L: CGFloat = 132
        // posisi loupe di atas kursor, di-clamp agar tetap di dalam frame
        let cx = min(max(l.x, L / 2), W - L / 2)
        var cy = l.y - L / 2 - 18
        if cy < L / 2 { cy = min(l.y + L / 2 + 18, H - L / 2) }

        return ZStack {
            scene(W: W, H: H)
                .frame(width: W, height: H)
                .scaleEffect(M, anchor: .topLeading)
                .offset(x: L / 2 - n.x * W * M, y: L / 2 - n.y * H * M)
                .frame(width: L, height: L, alignment: .topLeading)
                .clipShape(Circle())

            // crosshair
            Path { p in
                p.move(to: CGPoint(x: L / 2 - 8, y: L / 2)); p.addLine(to: CGPoint(x: L / 2 + 8, y: L / 2))
                p.move(to: CGPoint(x: L / 2, y: L / 2 - 8)); p.addLine(to: CGPoint(x: L / 2, y: L / 2 + 8))
            }
            .stroke(accent, lineWidth: 1.5)

            Circle().strokeBorder(.white, lineWidth: 3)
            Circle().strokeBorder(Theme.hairline)
        }
        .frame(width: L, height: L)
        .background(Color.black.opacity(0.15), in: Circle())
        .shadow(radius: 6)
        .position(x: cx, y: cy)
    }

    // MARK: Upload prompt

    private var uploadPrompt: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "photo.badge.plus").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Belum ada denah").font(.headline)
            Text("Upload gambar / PDF floor plan").font(.caption).foregroundStyle(.secondary)
            if let onUpload {
                GhostButton(title: "Pilih File Denah", systemImage: "folder", action: onUpload)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0xF7F8FA).opacity(0.92))
    }

    // MARK: Transform helpers (anchor .center)

    private func normalize(_ p: CGPoint, W: CGFloat, H: CGFloat) -> CGPoint {
        let cx = W / 2, cy = H / 2
        let px = (p.x - offset.width - cx) / zoom + cx
        let py = (p.y - offset.height - cy) / zoom + cy
        return CGPoint(x: min(max(px / W, 0), 1), y: min(max(py / H, 0), 1))
    }

    private func screenPoint(_ pt: NormPoint, W: CGFloat, H: CGFloat) -> CGPoint {
        let cx = W / 2, cy = H / 2
        return CGPoint(x: cx + (pt.x * W - cx) * zoom + offset.width,
                       y: cy + (pt.y * H - cy) * zoom + offset.height)
    }

    private func nearest(to p: CGPoint, W: CGFloat, H: CGFloat) -> Int? {
        var best: (Int, CGFloat)? = nil
        for (i, pt) in points.enumerated() {
            let s = screenPoint(pt, W: W, H: H)
            let d = hypot(p.x - s.x, p.y - s.y)
            if d <= hitRadius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    private func clamped(_ o: CGSize, W: CGFloat, H: CGFloat) -> CGSize {
        let maxX = W * (zoom - 1) / 2
        let maxY = H * (zoom - 1) / 2
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}

// MARK: - Dot (dengan affordance hapus saat hover)

private struct DotView: View {
    let number: Int
    let color: Color
    let hovered: Bool
    var body: some View {
        ZStack {
            Circle().fill(hovered ? Color.red : color)
                .frame(width: hovered ? 26 : 22, height: hovered ? 26 : 22)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            if hovered {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.caption2.bold()).foregroundStyle(.white)
            }
        }
        .shadow(radius: 1)
        .help("Klik untuk hapus titik ini")
    }
}

// MARK: - Background scenes

/// Faux top-view "frame CCTV" supaya zoom/pan/loupe kelihatan bekerja.
private struct FrameScene: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A2E37), Color(hex: 0x161922)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                let w = size.width, h = size.height
                // garis perspektif lantai
                var floor = Path()
                for i in 1..<6 {
                    let y = h * CGFloat(i) / 6
                    floor.move(to: CGPoint(x: 0, y: y)); floor.addLine(to: CGPoint(x: w, y: y))
                }
                ctx.stroke(floor, with: .color(.white.opacity(0.06)), lineWidth: 1)

                // beberapa "meja" (kotak) sebagai referensi visual
                let tables: [CGRect] = [
                    CGRect(x: 0.16, y: 0.30, width: 0.14, height: 0.10),
                    CGRect(x: 0.46, y: 0.24, width: 0.14, height: 0.10),
                    CGRect(x: 0.70, y: 0.34, width: 0.14, height: 0.10),
                    CGRect(x: 0.30, y: 0.58, width: 0.14, height: 0.10),
                    CGRect(x: 0.60, y: 0.60, width: 0.14, height: 0.10)
                ]
                for t in tables {
                    let r = CGRect(x: t.minX * w, y: t.minY * h, width: t.width * w, height: t.height * h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.10)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.18)), lineWidth: 1)
                }
            }
            Image(systemName: "video.fill")
                .font(.system(size: 30)).foregroundStyle(.white.opacity(0.10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
        }
    }
}

private struct GridScene: View {
    let cols: Int
    let rows: Int
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var grid = Path()
            for c in 0...cols {
                let x = size.width * CGFloat(c) / CGFloat(cols)
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for r in 0...rows {
                let y = size.height * CGFloat(r) / CGFloat(rows)
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(color), lineWidth: 1)
        }
    }
}

#Preview {
    let s = AnalysisSession()
    s.cameras = [SessionCamera(label: "Kamera 1", url: nil, resolution: "1920×1080", durationSec: 7200)]
    return CalibrationView()
        .environment(AppRouter())
        .environment(s)
        .frame(width: 1180, height: 820)
}
