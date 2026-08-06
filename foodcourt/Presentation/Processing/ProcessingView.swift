//
//  ProcessingView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//
import SwiftUI

@Observable
@MainActor
final class ProcessingViewModel {
    var stages: [ProcessingStage] = ProcessingStage.pipeline
    var progress: Double = 0        // 0–1
    var isDone: Bool = false
    var errorMessage: String?
    /// Kalimat apa adanya dari engine ("Deteksi + tracking…"), bukan tebakan.
    var stageText: String = "Menyiapkan…"
    private var task: Task<Void, Never>?

    var currentStageName: String {
        if let e = errorMessage { return e }
        return isDone ? "Selesai" : stageText
    }

    /// Menjalankan analisis SUNGGUHAN lewat engine.
    ///
    /// Sebelumnya layar ini memutar animasi berdurasi acak yang selalu
    /// berakhir sukses, apa pun isi videonya — bar penuh tanpa satu frame pun
    /// benar-benar diproses.
    func start(session: AnalysisSession, service: ProcessingService) {
        guard task == nil else { return }
        task = Task { @MainActor in
            session.isProcessing = true
            session.errorMessage = nil
            defer { session.isProcessing = false }
            do {
                for try await update in service.run(session) {
                    switch update {
                    case let .progress(stage, fraction):
                        stageText = stage
                        progress = min(1.0, max(progress, fraction))
                        session.stage = stage
                        session.progress = progress
                        tandai(progress)
                    case let .finished(hasil):
                        session.result = hasil
                        progress = 1.0
                        tandai(1.0)
                        isDone = true
                    }
                }
            } catch is CancellationError {
                // dibatalkan pengguna lewat tombol Kembali — bukan kegagalan
            } catch {
                errorMessage = error.localizedDescription
                session.errorMessage = errorMessage
            }
        }
    }

    /// Empat baris tahap di UI dipetakan dari satu pecahan progres, memakai
    /// batas yang sama dengan bobot di engine (lacak 0–0,75; sambung 0,76;
    /// render 0,80–0,99; analitik saat selesai).
    private func tandai(_ f: Double) {
        let batas = [0.75, 0.78, 0.99, 1.0]
        for i in stages.indices {
            stages[i].state = f >= batas[i] ? .done
                : (i == 0 || f >= batas[i - 1]) ? .active : .pending
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stages = ProcessingStage.pipeline
        progress = 0
        isDone = false
        errorMessage = nil
        stageText = "Menyiapkan…"
    }
}

struct ProcessingView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session
    @Environment(Sidecar.self) private var sidecar
    @State private var vm = ProcessingViewModel()

    private var service: ProcessingService {
        EngineProcessingService(api: EngineAPI(http: sidecar.http), sidecar: sidecar)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                SectionHeader(
                    title: "Memproses",
                    subtitle: vm.errorMessage != nil ? "Analisis gagal."
                        : vm.isDone ? "Analisis selesai."
                        : "Menjalankan pipeline pada footage kamu…"
                )

                if let e = vm.errorMessage {
                    InfoNote(text: e, systemImage: "exclamationmark.triangle")
                }

                HStack(alignment: .top, spacing: Space.l * scale) {
                    stagesPanel
                        .relativeWidth(0.42)
                    previewPanel
                        .frame(maxWidth: .infinity)
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.l)

            Spacer(minLength: 0)

            WizardFooter(onBack: { vm.cancel(); router.back() }) {
                PrimaryButton(title: "Lihat Hasil",
                              systemImage: "arrow.right",
                              enabled: vm.isDone) {
                    router.next()
                }
            }
        }
        .task { vm.start(session: session, service: service) }
    }

    // MARK: Panel tahap

    private var stagesPanel: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Progress keseluruhan").font(.headline)
                    Spacer()
                    Text("\(Int((vm.progress * 100).rounded()))%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                ProgressView(value: vm.progress)
                    .tint(Theme.accent)
                Text(vm.currentStageName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: Space.m) {
                ForEach(vm.stages) { stage in
                    StageRow(stage: stage)
                }
            }
        }
        .card()
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Preview deteksi").font(.headline)
            BoundingBoxPreview(active: !vm.isDone)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
            // Panel ini ILUSTRASI, bukan frame yang sedang diproses — membaca
            // frame hidup dari engine belum ada. Video beranotasi yang
            // sebenarnya muncul di layar Hasil setelah proses selesai.
            Text("Ilustrasi cara kerja deteksi — bukan frame yang sedang diproses. "
                 + "Video beranotasi sungguhan tampil di layar Hasil.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}


private struct StageRow: View {
    let stage: ProcessingStage
    var body: some View {
        HStack(spacing: Space.m) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 30, height: 30)
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
                    let r = CGRect(x: box.rect.minX * geo.size.width,
                                   y: box.rect.minY * geo.size.height,
                                   width: box.rect.width * geo.size.width,
                                   height: box.rect.height * geo.size.height)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                        Text("ID \(box.id)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent)
                            .foregroundStyle(.white)
                            .offset(y: -14)
                        // titik kaki
                        Circle().fill(.orange).frame(width: 5, height: 5)
                            .offset(x: r.width / 2 - 2.5, y: r.height - 2.5)
                    }
                    .position(x: r.midX, y: r.midY)
                    .opacity(active ? (phase ? 1 : 0.55) : 0.9)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = true
            }
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
