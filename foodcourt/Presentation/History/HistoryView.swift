//
//  HistoryView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import SwiftData

// ============================================================
//  Layar Riwayat — daftar analisis yang tersimpan (SwiftData).
//  Taruh di: Foodcourt/Sources/Presentation/History/HistoryView.swift
// ============================================================

struct HistoryView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(Sidecar.self) private var sidecar
    @Query(sort: \AnalysisRecord.date, order: .reverse) private var records: [AnalysisRecord]

    // Session TERPISAH untuk melihat riwayat — tidak mengganggu analisis yang sedang berjalan.
    @State private var viewerSession = AnalysisSession()
    @State private var selectedFolder: String?

    var body: some View {
        Group {
            if let selectedFolder {
                HistoryDetailView(
                    jobId: records.first(where: { $0.folder == selectedFolder })?.jobId ?? viewerSession.jobId,
                    viewerSession: viewerSession,
                    http: sidecar.http,
                    onClose: { self.selectedFolder = nil }
                )
                .environment(router)
            } else {
                historyList
            }
        }
    }

    private var historyList: some View {
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
    }

    private func open(_ rec: AnalysisRecord) {
        guard load(into: viewerSession, folder: rec.folder) else { return }
        selectedFolder = rec.folder
    }

    @discardableResult
    private func load(into s: AnalysisSession, folder: String) -> Bool {
        guard let loaded = HistoryStore.load(folder: folder) else { return false }
        s.reset()
        s.venueName = loaded.venueName
        if let vt = VenueType(rawValue: loaded.venueType) { s.venueType = vt }
        s.widthM = loaded.widthM
        s.heightM = loaded.heightM
        s.usesScaledCanvas = loaded.usesScaledCanvas
        s.jobId = loaded.jobId
        s.floorPlanURL = loaded.floorPlanURL
        s.customZones = loaded.customZones
        s.tableAnnotations = loaded.tables
        s.result = loaded.result
        s.trimStartSec = 0
        s.trimEndSec = loaded.durationSec
        s.overrideCameraCount = loaded.cameraCount
        s.historyFolder = folder      // edit zona di viewer ikut tersimpan
        return true
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

private struct HistoryDetailView: View {
    let jobId: String?
    let viewerSession: AnalysisSession
    let http: HTTPClient
    let onClose: () -> Void

    @SceneStorage("history.showsTanyaDataPanel") private var showsChat = true
    @State private var selectedMedia: ChatMediaDTO?
    @State private var restoreChatAfterArtifact = false

    var body: some View {
        Group {
            if let selectedMedia {
                ArtifactDetailView(
                    media: selectedMedia,
                    baseURL: http.baseURL,
                    onBack: closeArtifact
                )
            } else {
                detailLayout
            }
        }
        .environment(viewerSession)
    }

    private var detailLayout: some View {
        HStack(spacing: 0) {
            ResultsView(
                isHistory: true,
                onClose: onClose,
                onOpenChat: { withAnimation(.easeInOut(duration: 0.2)) { showsChat = true } },
                isChatVisible: showsChat
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsChat {
                Divider()
                if let jobId, !jobId.isEmpty {
                    HistoryChatInspector(
                        jobId: jobId,
                        http: http,
                        zones: viewerSession.customZones,
                        onOpenMedia: { media in
                            restoreChatAfterArtifact = showsChat
                            selectedMedia = media
                        },
                        onClose: { withAnimation(.easeInOut(duration: 0.2)) { showsChat = false } }
                    )
                    .frame(width: 420)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    LegacyChatUnavailable(
                        onClose: { withAnimation(.easeInOut(duration: 0.2)) { showsChat = false } }
                    )
                    .frame(width: 420)
                }
            }
        }
    }

    private func closeArtifact() {
        selectedMedia = nil
        if restoreChatAfterArtifact {
            showsChat = true
            restoreChatAfterArtifact = false
        }
    }
}

private struct LegacyChatUnavailable: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tanya Data").font(.headline)
                    Text("Tidak tersedia untuk riwayat ini")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.s))
                }
                .buttonStyle(.plain)
                .help("Tutup Tanya Data")
            }
            .padding(Space.m)
            Divider()
            ContentUnavailableView(
                "Tanya Data tidak tersedia",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                description: Text("Riwayat lama ini tidak memiliki jobId yang dapat dipetakan secara aman ke backend.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
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
