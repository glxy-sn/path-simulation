//
//  HistoryView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnalysisRecord.date, order: .reverse) private var records: [AnalysisRecord]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                HStack(alignment: .top) {
                    SectionHeader(
                        title: "Riwayat Analisis",
                        subtitle: "\(records.count) analisis tersimpan."
                    )
                    PrimaryButton(title: "Analisis Baru", systemImage: "plus") {
                        router.startNew()
                    }
                }

                if records.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: Space.m) {
                        ForEach(records) { rec in
                            HistoryRow(record: rec,
                                       onOpen: { open(rec) },
                                       onDelete: { remove(rec) })
                        }
                    }
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
    }

    private func open(_ rec: AnalysisRecord) {
        guard let loaded = HistoryStore.load(folder: rec.folder) else { return }
        session.reset()
        session.venueName = loaded.venueName
        if let vt = VenueType(rawValue: loaded.venueType) { session.venueType = vt }
        session.widthM = loaded.widthM
        session.heightM = loaded.heightM
        session.usesScaledCanvas = loaded.usesScaledCanvas
        session.floorPlanURL = loaded.floorPlanURL
        session.customZones = loaded.customZones
        session.result = loaded.result
        router.openResult()
    }

    private func remove(_ rec: AnalysisRecord) {
        HistoryStore.delete(folder: rec.folder)
        modelContext.delete(rec)
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Belum ada analisis").font(.headline)
            Text("Mulai dari “Analisis Baru”. Hasil akan otomatis tersimpan di sini.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .card()
    }
}

private struct HistoryRow: View {
    let record: AnalysisRecord
    var onOpen: () -> Void
    var onDelete: () -> Void

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
                    Text(record.venueName).font(.headline).lineLimit(1)
                    Tag(text: record.mode,
                        color: record.mode.localizedCaseInsensitiveContains("lengkap") ? Theme.accent : .orange)
                }
                Text("\(record.venueType) · \(record.dateText)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.l) {
                    stat("person.2", "\(record.totalVisitors) pengunjung")
                    stat("clock", record.avgDwellText)
                    stat("chart.line.uptrend.xyaxis", "puncak \(record.peakOccupancy)")
                    stat("camera", "\(record.cameraCount) kamera")
                }
                .padding(.top, 2)
            }

            Spacer()

            GhostButton(title: "Buka", systemImage: "arrow.up.right", action: onOpen)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.red).padding(6).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Hapus dari riwayat")
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
