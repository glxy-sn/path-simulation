//
//  RootView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct RootView: View {
    @State private var router = AppRouter()
    @State private var session = AnalysisSession()
    @State private var sidecar = Sidecar()
    @State private var installer = AssetInstaller()
    @State private var setupTask: Task<Void, Never>?
    private let referenceWidth: CGFloat = 1440

    var body: some View {
        Group {
            if case .ready = installer.phase {
                workspace
            } else {
                SetupView(installer: installer, onRetry: startSetup)
                    .frame(minWidth: 1060, minHeight: 700)
            }
        }
        .task { startSetup() }
    }

    /// Backend baru dinyalakan setelah asetnya lengkap; sebelum itu tidak ada
    /// runtime Python yang bisa dijalankan sama sekali.
    private func startSetup() {
        setupTask?.cancel()
        setupTask = Task {
            await installer.install()
            if case .ready = installer.phase {
                await sidecar.ensureRunning()
            }
        }
    }

    private var workspace: some View {
        GeometryReader { geo in
            let scale = geo.size.width / referenceWidth
            let menuWidth = min(max(geo.size.width * 0.16, 190), 240)

            VStack(spacing: 0) {
            backendBanner
            HStack(spacing: 0) {
                SideMenu(current: router.section,
                         onSelect: { router.open($0) })
                    .frame(width: menuWidth)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .environment(\.uiScale, scale)
            .environment(router)
            .environment(session)
            .environment(sidecar)
        }
        .frame(minWidth: 1060, minHeight: 700)
        .background(WindowBackground())
    }

    /// `launchError` sudah lama diisi tetapi tidak pernah ditampilkan, sehingga
    /// backend yang gagal nyala hanya terlihat sebagai aplikasi yang diam.
    @ViewBuilder private var backendBanner: some View {
        if let error = sidecar.launchError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The analysis engine is not running")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Retry") { Task { await sidecar.ensureRunning() } }
                        .controlSize(.small)
                }
                ScrollView(.vertical) {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            Divider()
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Wizard tetap hidup saat berpindah menu supaya proses analisis tidak restart.
            WizardContainer()
                .opacity(router.section == .newAnalysis ? 1 : 0)
                .allowsHitTesting(router.section == .newAnalysis)

            if router.section == .history {
                HistoryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WindowBackground())
            }
        }
    }
}

/// Wizard: stepper horizontal di atas, layar aktif di bawah.
private struct WizardContainer: View {
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HorizontalStepper(steps: FlowStep.allCases,
                              current: router.step,
                              isLocked: router.step == .processing && session.result == nil,
                              isEnabled: { isReachable($0) },
                              onSelect: { step in
                                  guard !(router.step == .processing && session.result == nil) else { return }
                                  guard isReachable(step) else { return }
                                  router.go(to: step)
                              })
                .spad(Space.xl, [.horizontal])
                .padding(.vertical, Space.m)
                .background(.bar)
                .overlay(Divider(), alignment: .bottom)

            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// No footage imported yet means nothing downstream can run, so every step
    /// past Import stays unreachable until at least one video is loaded.
    private func isReachable(_ step: FlowStep) -> Bool {
        guard step != .importFootage else { return true }
        return session.cameras.contains { $0.url != nil }
    }

    @ViewBuilder
    private var stepView: some View {
        switch router.step {
        case .importFootage: ImportView()
        case .calibration:   CalibrationView()
        case .processing:    ProcessingView()
        case .results:       ActiveResultsView()
        }
    }
}

private struct ActiveResultsView: View {
    @Environment(AnalysisSession.self) private var session
    @Environment(Sidecar.self) private var sidecar
    @State private var showsChat = false

    var body: some View {
        ResultsChatContainer(
            jobId: session.result?.jobId ?? session.jobId,
            http: sidecar.http,
            isHistory: false,
            onClose: nil,
            showsChat: $showsChat
        )
    }
}

private struct WindowBackground: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .overlay(Color.primary.opacity(0.015))
            .ignoresSafeArea()
    }
}

#Preview {
    RootView()
        .frame(width: 1280, height: 820)
}
