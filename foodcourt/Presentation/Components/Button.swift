//
//  Button.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI


struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s + 2)
            .foregroundStyle(Theme.onAccent)
            .background(enabled ? Theme.accentFill : Color.gray.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
 
struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s + 2)
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
