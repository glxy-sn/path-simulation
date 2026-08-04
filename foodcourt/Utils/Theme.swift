//
//  Theme.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8)  & 0xff) / 255,
            blue:  Double(hex & 0xff)         / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    static let accent      = Color(hex: 0x5457D6)
    static let accentSoft  = Color(hex: 0x5457D6, alpha: 0.12)

    static let hairline    = Color.primary.opacity(0.08)

    static let heatStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0x2B3A67, alpha: 0.0), location: 0.0),
        .init(color: Color(hex: 0x3B82F6), location: 0.35),
        .init(color: Color(hex: 0x22C55E), location: 0.55),
        .init(color: Color(hex: 0xFACC15), location: 0.75),
        .init(color: Color(hex: 0xEF4444), location: 1.0)
    ]
}


enum Space {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 16
    static let l:  CGFloat = 24
    static let xl: CGFloat = 40
}

enum Radius {
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
}


private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}


extension View {
    func relativeWidth(_ f: CGFloat) -> some View {
        containerRelativeFrame(.horizontal) { w, _ in w * f }
    }
    func relativeHeight(_ f: CGFloat) -> some View {
        containerRelativeFrame(.vertical) { h, _ in h * f }
    }

    func spad(_ base: CGFloat = Space.m, _ edges: Edge.Set = .all) -> some View {
        modifier(ScaledPadding(base: base, edges: edges))
    }
}

private struct ScaledPadding: ViewModifier {
    @Environment(\.uiScale) private var scale
    let base: CGFloat
    let edges: Edge.Set
    func body(content: Content) -> some View {
        content.padding(edges, base * scale)
    }
}
