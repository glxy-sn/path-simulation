//
//  Header.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
 
struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}
