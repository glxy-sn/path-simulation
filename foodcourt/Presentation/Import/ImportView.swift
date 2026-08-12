//
//  ImportView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

struct ImportView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l * scale) {
                    SectionHeader(
                        title: "Import Footage",
                        subtitle: "Upload rekaman CCTV dari tiap sudut, lalu beri label kameranya."
                    )
                    HStack(alignment: .top, spacing: Space.l * scale) {
                        ImportMainColumn(session: session) { addFiles(into: session) }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        ImportInspector(session: session)
                            .relativeWidth(0.30)
                    }
                }
                .spad(Space.xl, [.horizontal, .top])
                .padding(.bottom, Space.xl)
            }

            WizardFooter {
                PrimaryButton(title: "Lanjut ke Kalibrasi",
                              systemImage: "arrow.right",
                              enabled: !session.cameras.isEmpty) {
                    router.next()
                }
            }
        }
    }

    // MARK: pilih file + baca metadata

    private func addFiles(into session: AnalysisSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let cam = SessionCamera(label: "Kamera \(session.cameras.count + 1)", url: url)
            session.cameras.append(cam)
            loadMeta(cam.id, url: url, into: session)
        }
        session.normalizeTrim()
    }

    private func loadMeta(_ id: UUID, url: URL, into session: AnalysisSession) {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(d)
                if secs.isFinite, let i = session.cameras.firstIndex(where: { $0.id == id }) {
                    session.cameras[i].durationSec = secs
                }
                session.normalizeTrim()
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let i = session.cameras.firstIndex(where: { $0.id == id }) {
                let pixelSize = PixelSize(width: abs(size.width), height: abs(size.height))
                session.cameras[i].resolution = "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
                session.cameras[i].framePixelSize = pixelSize
            }
        }
    }
}

// MARK: - Kolom utama

private struct ImportMainColumn: View {
    @Bindable var session: AnalysisSession
    var onAdd: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            if session.cameras.isEmpty {
                DropZone(onTap: onAdd)
            } else {
                HStack {
                    FieldLabel(text: "Video terimpor (\(session.cameras.count))")
                    Spacer()
                    GhostButton(title: "Tambah File", systemImage: "plus") { onAdd() }
                }

                VStack(spacing: Space.s) {
                    ForEach(session.cameras) { cam in
                        CameraRow(
                            camera: cam,
                            onLabelChange: { newLabel in
                                if let i = session.cameras.firstIndex(where: { $0.id == cam.id }) {
                                    session.cameras[i].label = newLabel
                                }
                            },
                            onOffsetChange: { offset in
                                if let i = session.cameras.firstIndex(where: { $0.id == cam.id }) {
                                    session.cameras[i].timeOffsetSec = min(300, max(-300, offset))
                                    session.normalizeTrim()
                                }
                            },
                            onRemove: {
                                session.cameras.removeAll { $0.id == cam.id }
                                session.normalizeTrim()
                            }
                        )
                    }
                }

                if session.timelineMax > 0 {
                    GlobalTrimCard(startSec: $session.trimStartSec,
                                   endSec: $session.trimEndSec,
                                   minSec: session.timelineMin,
                                   maxSec: session.timelineMax,
                                   cameras: session.previews)
                }
            }
        }
    }
}

// MARK: - Inspector

private struct ImportInspector: View {
    @Bindable var session: AnalysisSession
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l * scale) {
            VStack(alignment: .leading, spacing: Space.m) {
                FieldLabel(text: "Detail Venue")
                field("Nama venue") {
                    TextField("mis. Pujasera Kampus", text: $session.venueName).textFieldStyle(.roundedBorder)
                }
                field("Tipe") {
                    Picker("", selection: $session.venueType) {
                        ForEach(VenueType.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                HStack(spacing: Space.s) {
                    field("Lebar (m)") { TextField("10", text: $session.widthM).textFieldStyle(.roundedBorder) }
                    field("Panjang (m)") { TextField("7.5", text: $session.heightM).textFieldStyle(.roundedBorder) }
                }
                InfoNote(text: "Dimensi venue jadi referensi skala. Tanpa ini, dwell & jarak tidak bermakna.")
            }
            .card()
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Baris kamera (hapus by id, tombol andal)

private struct CameraRow: View {
    let camera: SessionCamera
    var onLabelChange: (String) -> Void
    var onOffsetChange: (Double) -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 64, height: 40)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Label kamera",
                          text: Binding(get: { camera.label }, set: { onLabelChange($0) }))
                    .textFieldStyle(.plain).font(.headline)
                Text(camera.url?.lastPathComponent ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(camera.durationSec > 0 ? timecode(camera.durationSec) : "—").font(.caption.monospacedDigit())
                Text(camera.resolution).font(.caption).foregroundStyle(.secondary)
            }

            Divider().frame(height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Offset waktu").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.xs) {
                    TextField(
                        "0,0",
                        value: Binding(
                            get: { camera.timeOffsetSec },
                            set: { onOffsetChange($0) }
                        ),
                        format: .number.precision(.fractionLength(1...2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    Stepper(
                        "",
                        value: Binding(
                            get: { camera.timeOffsetSec },
                            set: { onOffsetChange($0) }
                        ),
                        in: -300...300,
                        step: 0.1
                    )
                    .labelsHidden()
                    Text("s").font(.caption).foregroundStyle(.secondary)
                }
            }
            .help("Waktu sumber = waktu global + offset. Positif membaca frame lebih akhir.")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Hapus video")
        }
        .card(padding: Space.m)
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    @Environment(\.uiScale) private var scale
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Drag & drop video CCTV di sini").font(.headline)
            Text("atau").font(.caption).foregroundStyle(.secondary)
            GhostButton(title: "Pilih File", systemImage: "folder") { onTap() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl * scale)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(Theme.hairline)
        )
        .onTapGesture { onTap() }
    }
}

#Preview {
    ImportView()
        .environment(AppRouter())
        .environment(AnalysisSession())
        .frame(width: 1100, height: 780)
}
