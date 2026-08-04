//
//  MetricTile.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI


struct MetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    let systemImage: String
    var tint: Color = Theme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.title3)
                Spacer()
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.l)
    }
}
