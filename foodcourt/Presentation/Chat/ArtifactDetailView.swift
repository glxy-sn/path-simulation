import SwiftUI

struct ArtifactDetailView: View {
    let media: ChatMediaDTO
    let baseURL: URL
    var onBack: (() -> Void)? = nil

    @State private var image: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.callout.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.s))
                    }
                    .buttonStyle(.plain)
                    .help("Kembali ke chat")
                }
                Text(media.caption)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(Space.m)
            Divider()

            ZStack {
                Color.primary.opacity(0.025)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(Space.m)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Gambar gagal dimuat",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Memuat gambar resolusi penuh…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .task { await load() }
    }

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
