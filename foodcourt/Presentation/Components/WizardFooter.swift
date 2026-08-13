//
//  WizardFooter.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct WizardFooter<Trailing: View>: View {
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            if let onBack {
                GhostButton(title: "Back", systemImage: "chevron.left", action: onBack)
            }
            Spacer()
            trailing()
        }
        .spad(Space.l, [.horizontal])
        .padding(.vertical, Space.m)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}
