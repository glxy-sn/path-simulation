//
//  HistoryView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

@Observable
final class HistoryViewModel {
    var entries: [HistoryEntry] = HistoryEntry.samples
}

struct HistoryView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @State private var vm = HistoryViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                HStack(alignment: .top) {
                    SectionHeader(
                        title: "Riwayat Analisis",
                        subtitle: "\(vm.entries.count) analisis tersimpan."
                    )
                    PrimaryButton(title: "Analisis Baru", systemImage: "plus") {
                        router.startNew()
                    }
                }

                if vm.entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: Space.m) {
                        ForEach(vm.entries) { entry in
                            HistoryRow(entry: entry) { router.openResult() }
                        }
                    }
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Belum ada analisis").font(.headline)
            Text("Mulai dari “Analisis Baru”.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .card()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: Space.l) {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.s) {
                    Text(entry.venue).font(.headline)
                    Tag(text: entry.mode,
                        color: entry.mode == "Mode Lengkap" ? Theme.accent : .orange)
                }
                Text("\(entry.type) · \(entry.dateText)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.l) {
                    stat("person.2", "\(entry.visitors) pengunjung")
                    stat("clock", entry.avgDwellText)
                    stat("camera", "\(entry.cameraCount) kamera")
                }
                .padding(.top, 2)
            }

            Spacer()

            GhostButton(title: "Buka", systemImage: "arrow.up.right", action: onOpen)
        }
        .card(padding: Space.m)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HistoryView()
        .environment(AppRouter())
        .frame(width: 1100, height: 780)
}
