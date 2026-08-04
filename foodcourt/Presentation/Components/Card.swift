//
//  Card.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

extension View {
    func card(padding: CGFloat = Space.l, radius: CGFloat = Radius.m) -> some View {
        modifier(CardStyle(padding: padding, radius: radius))
    }
}
 
private struct CardStyle: ViewModifier {
    @Environment(\.uiScale) private var scale
    let padding: CGFloat
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding * scale)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }
}
