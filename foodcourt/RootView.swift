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
    // Percakapan hidup selama aplikasi terbuka. Waktu model ini masih @State di
    // dalam ChatView, pindah tab menghancurkannya — tanya-jawab yang baru saja
    // dibaca hilang tanpa peringatan.
    @State private var chat = ChatViewModel()
    /// Panel chat terbuka atau tertutup. Disimpan di sini, bukan di dalam
    /// panelnya, supaya pindah langkah wizard tidak menutupnya sendiri.
    @State private var chatTerbuka = false
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
                    .overlay(alignment: .bottomTrailing) { tombolChat }

                // Panel chat DI SAMPING hasil, bukan tab tersendiri: pertanyaan
                // yang muncul saat melihat hasil ("meja mana yang paling ramai")
                // paling enak dijawab sambil grafiknya masih kelihatan.
                if chatTerbuka {
                    Divider()
                    ChatView()
                        .frame(width: min(max(geo.size.width * 0.30, 340), 460))
                        .transition(.move(edge: .trailing))
                }
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

    private var tombolChat: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { chatTerbuka.toggle() }
        } label: {
            Label(chatTerbuka ? "Tutup" : "Tanya Data",
                  systemImage: chatTerbuka
                      ? "sidebar.trailing"
                      : "bubble.left.and.text.bubble.right")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(
                    Capsule().fill(.thinMaterial)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                )
        }
        .buttonStyle(.plain)
        .padding(Space.l)
        .help("Tanya-jawab tentang hasil analisis")
    }

    @ViewBuilder
    private var content: some View {
        switch router.section {
        case .newAnalysis: WizardContainer()
        case .history:     HistoryView()
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
