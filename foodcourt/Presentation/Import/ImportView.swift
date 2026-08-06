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
                session.cameras[i].resolution = "\(Int(abs(size.width)))×\(Int(abs(size.height)))"
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
                    ForEach($session.cameras) { $cam in
                        CameraRow(cam: $cam) {
                            session.cameras.removeAll { $0.id == cam.id }
                            session.normalizeTrim()
                        }
                    }
                }

                if session.timelineMax > 0 {
                    GlobalTrimCard(startSec: $session.trimStartSec,
                                   endSec: $session.trimEndSec,
                                   maxSec: session.timelineMax,
                                   previewURL: session.previewURL)
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
                    field("Lebar (m)") { TextField("20", text: $session.widthM).textFieldStyle(.roundedBorder) }
                    field("Panjang (m)") { TextField("15", text: $session.heightM).textFieldStyle(.roundedBorder) }
                }
                InfoNote(text: "Dimensi venue jadi referensi skala. Tanpa ini, dwell & jarak tidak bermakna.")
            }
            .card()

            VStack(alignment: .leading, spacing: Space.m) {
                FieldLabel(text: "Mode Analisis")
                Picker("", selection: $session.mode) {
                    ForEach(AnalysisMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(session.mode.detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Baris kamera

private struct CameraRow: View {
    @Binding var cam: SessionCamera
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 64, height: 40)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Label kamera", text: $cam.label).textFieldStyle(.plain).font(.headline)
                Text(cam.url?.lastPathComponent ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(cam.durationSec > 0 ? timecode(cam.durationSec) : "—").font(.caption.monospacedDigit())
                Text(cam.resolution).font(.caption).foregroundStyle(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
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
