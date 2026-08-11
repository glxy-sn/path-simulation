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
    // Percakapan hidup selama aplikasi terbuka. Ketika model ini masih @State
    // di dalam ChatView, pindah ke tab lain menghancurkannya — tanya-jawab yang
    // baru saja dibaca hilang tanpa peringatan, dan pertanyaan lama harus
    // diketik ulang.
    @State private var chat = ChatViewModel()
    private let referenceWidth: CGFloat = 1440

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / referenceWidth
            let menuWidth = min(max(geo.size.width * 0.16, 190), 240)

            HStack(spacing: 0) {
                SideMenu(current: router.section,
                         onSelect: { router.open($0) })
                    .frame(width: menuWidth)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.uiScale, scale)
            .environment(router)
            .environment(session)
            .environment(sidecar)
            .environment(chat)
        }
        .frame(minWidth: 1060, minHeight: 700)
        .background(WindowBackground())
        .task { await sidecar.checkHealth() }
    }

    @ViewBuilder
    private var content: some View {
        switch router.section {
        case .newAnalysis: WizardContainer()
        case .history:     HistoryView()
        case .chat:        ChatView()
        }
    }
}

/// Wizard: stepper horizontal di atas, layar aktif di bawah.
private struct WizardContainer: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            HorizontalStepper(steps: FlowStep.allCases,
                              current: router.step,
                              onSelect: { router.go(to: $0) })
                .spad(Space.xl, [.horizontal])
                .padding(.vertical, Space.m)
                .background(.bar)
                .overlay(Divider(), alignment: .bottom)

            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch router.step {
        case .importFootage: ImportView()
        case .calibration:   CalibrationView()
        case .processing:    ProcessingView()
        case .results:       ResultsView()
        }
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
