//
//  ProcessingView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import SwiftData
internal import Combine

struct ProcessingView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.modelContext) private var modelContext

    @State private var stages = ProcessingStage.pipeline
    @State private var progress = 0.0
    @State private var shown = 0.0
    @State private var done = false
    @State private var errorMsg: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                SectionHeader(
                    title: "Processing",
                    subtitle: done ? "Analysis complete."
                        : (errorMsg == nil ? "Running the pipeline on your footage…" : "Something went wrong.")
                )
                stagesPanel.frame(maxWidth: .infinity)
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.l)

            Spacer(minLength: 0)

            WizardFooter(onBack: done ? { router.back() } : nil) {
                HStack(spacing: Space.s) {
                    if !done && errorMsg == nil {
                        GhostButton(title: "Cancel", systemImage: "xmark") { router.back() }
                    }
                    PrimaryButton(title: "View Results", systemImage: "arrow.right", enabled: done) {
                        router.next()
                    }
                }
            }
        }
        .task { await runIfNeeded() }
        .onChange(of: progress) { _, p in
            if p > shown { withAnimation(.easeOut(duration: 0.3)) { shown = p } }
            if p >= 1 { withAnimation(.easeOut(duration: 0.3)) { shown = 1 } }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard !done, errorMsg == nil else { return }
            let ceiling = min(0.99, progress + 0.14)   // merayap pelan biar tak terlihat macet
            if shown < ceiling { shown = min(ceiling, shown + max(0.004, (ceiling - shown) * 0.06)) }
        }
    }

    // MARK: run engine

    private func runIfNeeded() async {
        if session.result != nil {          // sudah pernah selesai (mis. balik dari Hasil)
            for i in stages.indices { stages[i].state = .done }
            progress = 1; done = true
            return
        }
        if done || errorMsg != nil { return }
        await run()
    }

    private func run() async {
        errorMsg = nil
        let service = EngineProcessingService(api: EngineAPI(http: sidecar.http), sidecar: sidecar)
        do {
            for try await update in service.run(session) {
                switch update {
                case .progress(let stage, let frac):
                    applyStage(stage, frac)
                case .finished(let result):
                    session.jobId = result.jobId
                    session.result = result
                    saveToHistory(result)
                    progress = 1
                    for i in stages.indices { stages[i].state = .done }
                    done = true
                }
            }
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveToHistory(_ result: AnalysisResult) {
        let folder = UUID().uuidString
        let saved = SavedAnalysis(from: session, result: result)
        let floorSrc = session.usesScaledCanvas ? nil : session.floorPlanURL
        HistoryStore.writeMeta(saved, folder: folder, floorPlanSource: floorSrc)

        var arts: [(name: String, url: URL)] = []
        if let u = result.heatmapURL, let f = saved.heatmapFile { arts.append((f, u)) }
        if let u = result.pathVideoURL, let f = saved.pathVideoFile { arts.append((f, u)) }
        if let u = result.combinedVideoURL, let f = saved.combinedVideoFile { arts.append((f, u)) }
        if let u = result.fusionDiagnosticsURL, let f = saved.fusionDiagnosticsFile { arts.append((f, u)) }
        for (i, ov) in result.overlayVideos.enumerated() where i < saved.overlays.count {
            arts.append((saved.overlays[i].file, ov.url))
        }

        let rec = AnalysisRecord(from: session, result: result)
        rec.folder = folder
        modelContext.insert(rec)
        try? modelContext.save()
        session.historyFolder = folder   // agar edit zona di Hasil ikut tersimpan

        let artsCopy = arts
        Task.detached { await HistoryStore.downloadArtifacts(artsCopy, folder: folder) }
    }

    private func applyStage(_ name: String, _ fraction: Double) {
        progress = max(progress, fraction)
        let order = ["detection", "tracking", "fusion", "analytics"]
        let idx = order.firstIndex(of: name) ?? (name == "done" ? stages.count : 0)
        for i in stages.indices {
            stages[i].state = i < idx ? .done : (i == idx ? .active : .pending)
        }
    }

    private func retry() async {
        stages = ProcessingStage.pipeline
        progress = 0; done = false; errorMsg = nil
        await run()
    }

    // MARK: panels

    private var stagesPanel: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Overall Progress").font(.headline)
                    Spacer()
                    Text("\(Int((shown * 100).rounded()))%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                ProgressView(value: shown).tint(Theme.accent)
                Text(currentStageName).font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: Space.m) {
                ForEach(stages) { stage in StageRow(stage: stage) }
            }

            if let errorMsg {
                Divider()
                VStack(alignment: .leading, spacing: Space.s) {
                    Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    GhostButton(title: "Retry", systemImage: "arrow.clockwise") {
                        Task { await retry() }
                    }
                }
            }
        }
        .card()
    }

    private var currentStageName: String {
        if done { return "Complete" }
        if errorMsg != nil { return "Stopped" }
        return stages.first { $0.state == .active }?.name ?? "Preparing…"
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Preview").font(.headline)
            BoundingBoxPreview(active: !done)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
            Text("Video deteksi + ID + titik kaki bisa dilihat di layar Hasil setelah selesai.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Baris tahap

private struct StageRow: View {
    let stage: ProcessingStage
    var body: some View {
        HStack(spacing: Space.m) {
            ZStack {
                Circle().fill(fill).frame(width: 30, height: 30)
                switch stage.state {
                case .done:
                    Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold())
                case .active:
                    ProgressView().controlSize(.small).tint(.white)
                case .pending:
                    Image(systemName: stage.systemImage).foregroundStyle(.secondary).font(.caption)
                }
            }
            Text(stage.name)
                .font(.callout.weight(stage.state == .active ? .semibold : .regular))
                .foregroundStyle(stage.state == .pending ? .secondary : .primary)
            Spacer()
        }
    }
    private var fill: Color {
        switch stage.state {
        case .done, .active: return Theme.accent
        case .pending:       return Color.primary.opacity(0.08)
        }
    }
}

// MARK: - Preview kotak deteksi (dekoratif selama proses)

private struct BoundingBoxPreview: View {
    let active: Bool
    @State private var phase = false
    private let boxes: [(id: Int, rect: CGRect)] = [
        (7,  CGRect(x: 0.18, y: 0.30, width: 0.10, height: 0.34)),
        (12, CGRect(x: 0.42, y: 0.26, width: 0.11, height: 0.40)),
        (23, CGRect(x: 0.64, y: 0.34, width: 0.09, height: 0.30)),
        (31, CGRect(x: 0.80, y: 0.42, width: 0.08, height: 0.26))
    ]
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x232733), Color(hex: 0x12151D)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(boxes, id: \.id) { box in
                    let r = CGRect(x: box.rect.minX * geo.size.width, y: box.rect.minY * geo.size.height,
                                   width: box.rect.width * geo.size.width, height: box.rect.height * geo.size.height)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                        Text("ID \(box.id)").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent).foregroundStyle(.white).offset(y: -14)
                        Circle().fill(.orange).frame(width: 5, height: 5)
                            .offset(x: r.width / 2 - 2.5, y: r.height - 2.5)
                    }
                    .position(x: r.midX, y: r.midY)
                    .opacity(active ? (phase ? 1 : 0.55) : 0.9)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

#Preview {
    ProcessingView()
        .environment(AppRouter())
        .environment(AnalysisSession())
        .environment(Sidecar())
        .frame(width: 1180, height: 820)
}
