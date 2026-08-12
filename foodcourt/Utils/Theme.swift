//
//  Theme.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

// MARK: - Warna

extension Color {
    /// Init dari hex, contoh: Color(hex: 0x5457D6)
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
    // Palet: Vanilla Cream / Blush Petal / Rosewood / Sage Leaf / Misty Sky / Midnight Lagoon
    static let accent      = Color(hex: 0x2D3A47)              // Midnight Lagoon
    static let accentSoft  = Color(hex: 0x2D3A47, alpha: 0.12)

    static let cream       = Color(hex: 0xFFF7E6)
    static let blush       = Color(hex: 0xF7C8D3)
    static let rosewood    = Color(hex: 0xB46A72)
    static let sage        = Color(hex: 0xA8B58A)
    static let sky         = Color(hex: 0xA9B7C6)
    static let midnight    = Color(hex: 0x2D3A47)

    /// Palet warna untuk zona / path / kategori.
    static let palette: [UInt] = [0xB46A72, 0xA8B58A, 0xA9B7C6, 0x2D3A47, 0xD79AA2, 0x8FA07C]

    /// Garis pemisah / border halus.
    static let hairline    = Color.primary.opacity(0.08)

    /// Gradien untuk heatmap (rendah → tinggi) — warna fungsional standar, bukan palet app.
    static let heatStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0x2B3A67, alpha: 0.0), location: 0.0),
        .init(color: Color(hex: 0x3B82F6), location: 0.35),
        .init(color: Color(hex: 0x22C55E), location: 0.55),
        .init(color: Color(hex: 0xFACC15), location: 0.75),
        .init(color: Color(hex: 0xEF4444), location: 1.0)
    ]
}

// MARK: - Skala spacing & radius (nilai dasar pada window acuan)

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

// MARK: - uiScale (dibaca sekali di RootView, dipakai untuk padding proporsional)

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - Helper layout responsif

extension View {
    /// Lebar sebagai fraksi container terdekat (macOS 14+). Contoh: .relativeWidth(0.28)
    func relativeWidth(_ f: CGFloat) -> some View {
        containerRelativeFrame(.horizontal) { w, _ in w * f }
    }
    func relativeHeight(_ f: CGFloat) -> some View {
        containerRelativeFrame(.vertical) { h, _ in h * f }
    }

    /// Padding proporsional: base × uiScale. Contoh: .spad(Space.xl, [.horizontal])
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
