import SwiftUI

struct ArtifactDetailView: View {
    let media: ChatMediaDTO
    let baseURL: URL

    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var errorMessage: String?
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.caption).font(.headline)
                    if let area = media.selectedAreaId {
                        Text(area).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Space.s) {
                        if let kind = media.areaKind { Text(kind) }
                        if let confidence = media.confidence { Text("confidence \(confidence.formatted(.number.precision(.fractionLength(2))))") }
                        if let support = media.supportLevel { Text(support) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let metrics = media.metricSummary, !metrics.isEmpty {
                        Text(metrics.sorted(by: { $0.key < $1.key })
                            .map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let limitations = media.limitations, !limitations.isEmpty {
                        Text("Keterbatasan: \(limitations.joined(separator: " · "))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer()
                controls
            }
            .padding(Space.m)
            Divider()

            GeometryReader { geo in
                ZStack {
                    Color.primary.opacity(0.025)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .scaleEffect(zoom)
                            .offset(pan)
                            .gesture(panGesture)
                            .simultaneousGesture(zoomGesture)
                    } else if let errorMessage {
                        ContentUnavailableView("Gambar gagal dimuat", systemImage: "photo.badge.exclamationmark",
                                               description: Text(errorMessage))
                    } else {
                        ProgressView("Memuat gambar resolusi penuh…")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear { viewportSize = geo.size }
                .onChange(of: geo.size) { _, value in viewportSize = value }
            }
        }
        .navigationTitle("Detail Area")
        .task { await load() }
    }

    private var controls: some View {
        HStack(spacing: Space.s) {
            Button { setZoom(zoom - 0.25) } label: { Image(systemName: "minus") }.help("Perkecil")
            Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { setZoom(zoom + 0.25) } label: { Image(systemName: "plus") }.help("Perbesar")
            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { fitToWindow() }
            Button("Actual Size", systemImage: "1.magnifyingglass") { actualSize() }
            Button("Reset", systemImage: "arrow.counterclockwise") { reset() }
        }
        .buttonStyle(.bordered)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: basePan.width + value.translation.width,
                             height: basePan.height + value.translation.height)
            }
            .onEnded { _ in basePan = pan }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = min(8, max(0.25, baseZoom * value.magnification)) }
            .onEnded { _ in baseZoom = zoom }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(8, max(0.25, value)); baseZoom = zoom
        if zoom <= 1 { pan = .zero; basePan = .zero }
    }

    private func fitToWindow() { zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero }

    private func actualSize() {
        guard let image, image.size.width > 0, image.size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        let fittedScale = min(viewportSize.width / image.size.width,
                              viewportSize.height / image.size.height)
        setZoom(1 / max(fittedScale, 0.001))
    }

    private func reset() { fitToWindow() }

    private func load() async {
        guard let url = URL(string: media.artifactURL, relativeTo: baseURL)?.absoluteURL else {
            errorMessage = "URL artefak tidak valid."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let loaded = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            image = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
