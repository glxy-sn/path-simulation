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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnalysisRecord.date, order: .reverse) private var records: [AnalysisRecord]

    // Session TERPISAH untuk melihat riwayat — tidak mengganggu analisis yang sedang berjalan.
    @State private var viewerSession = AnalysisSession()
    @State private var showViewer = false

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
                            HistoryRow(record: rec, onDelete: { remove(rec) })
                                .contentShape(Rectangle())
                                .onTapGesture { open(rec) }
                        }
                    }
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
        .sheet(isPresented: $showViewer) {
            ResultsView(isHistory: true)
                .environment(viewerSession)
                .environment(router)
                .frame(minWidth: 960, minHeight: 680)
        }
    }

    private func open(_ rec: AnalysisRecord) {
        guard let loaded = HistoryStore.load(folder: rec.folder) else { return }
        let s = viewerSession
        s.reset()
        s.venueName = loaded.venueName
        if let vt = VenueType(rawValue: loaded.venueType) { s.venueType = vt }
        s.widthM = loaded.widthM
        s.heightM = loaded.heightM
        s.usesScaledCanvas = loaded.usesScaledCanvas
        s.floorPlanURL = loaded.floorPlanURL
        s.customZones = loaded.customZones
        s.result = loaded.result
        s.trimStartSec = 0
        s.trimEndSec = loaded.durationSec
        s.overrideCameraCount = loaded.cameraCount
        s.historyFolder = rec.folder      // edit zona di viewer ikut tersimpan
        showViewer = true
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
                Text(record.venueName).font(.headline).lineLimit(1)
                Text("\(record.venueType) · \(record.dateText)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.l) {
                    stat("person.2", "\(record.totalVisitors) pengunjung")
                    stat("clock", record.avgDwellText)
                    stat("chart.line.uptrend.xyaxis", "puncak \(record.peakOccupancy)")
                    stat("camera", "\(record.cameraCount) kamera")
                    stat("timer", timecode(record.durationSec))
                }
                .padding(.top, 2)
            }

            Spacer()

            Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary).padding(6).contentShape(Rectangle())
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
