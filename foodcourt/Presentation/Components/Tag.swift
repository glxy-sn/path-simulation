//
//  Tag.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct Tag: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
