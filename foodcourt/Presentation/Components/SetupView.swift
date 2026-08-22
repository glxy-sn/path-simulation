//
//  SetupView.swift
//  foodcourt
//
//  Layar pertama-buka: mengunduh runtime dan model sebelum aplikasi bisa dipakai.
//

import SwiftUI

struct SetupView: View {
    let installer: AssetInstaller
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)

            VStack(spacing: Space.xs) {
                Text("Setting up U See")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch installer.phase {
            case .downloading(let label, let fraction, let received, let total):
                VStack(spacing: Space.xs) {
                    ProgressView(value: fraction)
                        .frame(width: 380)
                    HStack {
                        Text(label)
                        Spacer()
                        Text("\(byteText(received)) of \(byteText(total))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 380)
                }
            case .checking, .verifying, .installing:
                ProgressView().controlSize(.small)
            case .failed(let reason):
                VStack(spacing: Space.s) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                    Button("Try Again", action: onRetry)
                        .controlSize(.large)
                }
            case .ready:
                EmptyView()
            }

            if case .failed = installer.phase {} else {
                Text("You can leave this running and use other apps. Downloads resume where they left off if the connection drops, but quitting U See pauses them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var subtitle: String {
        switch installer.phase {
        case .checking:
            return "Checking what needs to be downloaded…"
        case .downloading:
            return "This happens once. Afterwards U See runs entirely offline."
        case .verifying(let label):
            return "Verifying \(label)…"
        case .installing(let label):
            return "Unpacking \(label)…"
        case .ready:
            return "Ready."
        case .failed:
            return "Setup could not finish."
        }
    }

    private func byteText(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
