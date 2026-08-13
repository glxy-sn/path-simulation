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
                        title: "Analysis History",
                        subtitle: "\(records.count) saved analyses."
                    )
                    PrimaryButton(title: "New Analysis", systemImage: "plus") {
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
            Text("No analyses yet").font(.headline)
            Text("Start from New Analysis. Results are saved here automatically.")
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
                description: Text("This old history entry has no jobId that can be safely mapped to the backend.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }
}

private struct HistoryRow: View {
    let record: AnalysisRecord
    var onDelete: () -> Void
    @State private var thumb: NSImage? = nil

    var body: some View {
        HStack(spacing: Space.l) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Theme.accentSoft.overlay(
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.title2).foregroundStyle(Theme.accent)
                    )
                }
            }
            .frame(width: 104, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.venueName).font(.headline).lineLimit(1)
                Text("\(record.venueType) · \(record.dateText)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.l) {
                    stat("person.2", "\(record.totalVisitors) visitors")
                    stat("clock", record.avgDwellText)
                    stat("chart.line.uptrend.xyaxis", "peak \(record.peakOccupancy)")
                    stat("camera", "\(record.cameraCount) cameras")
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
            .help("Remove from history")
        }
        .card(padding: Space.m)
        .task(id: record.folder) { thumb = await HistoryStore.thumbnail(folder: record.folder) }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
