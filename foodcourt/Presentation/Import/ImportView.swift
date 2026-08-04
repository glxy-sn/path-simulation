//
//  ImportView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

@Observable
final class ImportViewModel {
    var clips: [CameraClip] = CameraClip.samples
    var venueName: String = ""
    var venueType: VenueType = .pujasera
    var widthM: String = "20"
    var heightM: String = "15"
    var mode: AnalysisMode = .lengkap

    var canContinue: Bool { !clips.isEmpty }

    func removeClip(_ clip: CameraClip) {
        clips.removeAll { $0.id == clip.id }
    }

    func addFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            clips.append(
                CameraClip(
                    label: "Kamera \(clips.count + 1)",
                    fileName: url.lastPathComponent,
                    duration: "—",
                    resolution: "—"
                )
            )
        }
    }
}

struct ImportView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @State private var vm = ImportViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l * scale) {
                    SectionHeader(
                        title: "Import Footage",
                        subtitle: "Upload rekaman CCTV dari tiap sudut, lalu beri label kameranya."
                    )

                    HStack(alignment: .top, spacing: Space.l * scale) {
                        mainColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        inspector
                            .relativeWidth(0.30)
                    }
                }
                .spad(Space.xl, [.horizontal, .top])
                .padding(.bottom, Space.xl)
            }

            WizardFooter {
                PrimaryButton(title: "Lanjut ke Kalibrasi",
                              systemImage: "arrow.right",
                              enabled: vm.canContinue) {
                    router.next()
                }
            }
        }
    }

    // MARK: Kolom utama

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            DropZone { vm.addFilesViaPanel() }

            HStack {
                FieldLabel(text: "Video terimpor (\(vm.clips.count))")
                Spacer()
            }

            if vm.clips.isEmpty {
                Text("Belum ada video. Tambahkan minimal satu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: Space.s) {
                    ForEach($vm.clips) { $clip in
                        ClipRow(clip: $clip) { vm.removeClip(clip) }
                    }
                }
            }
        }
    }

    // MARK: Inspector kanan

    private var inspector: some View {
        VStack(alignment: .leading, spacing: Space.l * scale) {
            VStack(alignment: .leading, spacing: Space.m) {
                FieldLabel(text: "Detail Venue")

                labeledField("Nama venue") {
                    TextField("mis. Pujasera Kampus", text: $vm.venueName)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("Tipe") {
                    Picker("", selection: $vm.venueType) {
                        ForEach(VenueType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }

                HStack(spacing: Space.s) {
                    labeledField("Lebar (m)") {
                        TextField("20", text: $vm.widthM).textFieldStyle(.roundedBorder)
                    }
                    labeledField("Tinggi (m)") {
                        TextField("15", text: $vm.heightM).textFieldStyle(.roundedBorder)
                    }
                }

                InfoNote(text: "Dimensi venue jadi referensi skala. Tanpa ini, dwell & jarak tidak bermakna.")
            }
            .card()

            VStack(alignment: .leading, spacing: Space.m) {
                FieldLabel(text: "Mode Analisis")
                Picker("", selection: $vm.mode) {
                    ForEach(AnalysisMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(vm.mode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }

    private func labeledField<Content: View>(_ label: String,
                                             @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    @Environment(\.uiScale) private var scale
    var onTap: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Drag & drop video CCTV di sini")
                .font(.headline)
            Text("atau")
                .font(.caption)
                .foregroundStyle(.secondary)
            GhostButton(title: "Pilih File", systemImage: "folder") { onTap() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl * scale)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(isTargeted ? Theme.accentSoft : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? Theme.accent : Theme.hairline)
        )
        .onTapGesture { onTap() }
    }
}

// MARK: - Baris klip

private struct ClipRow: View {
    @Binding var clip: CameraClip
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 64, height: 40)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Label kamera", text: $clip.label)
                    .textFieldStyle(.plain)
                    .font(.headline)
                Text(clip.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(clip.duration).font(.caption.monospacedDigit())
                Text(clip.resolution).font(.caption).foregroundStyle(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .card(padding: Space.m)
    }
}

#Preview {
    ImportView()
        .environment(AppRouter())
        .frame(width: 1100, height: 780)
}
