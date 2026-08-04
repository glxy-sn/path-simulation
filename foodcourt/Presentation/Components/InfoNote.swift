//
//  InfoNote.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct InfoNote: View {
    let text: String
    var systemImage: String = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }
}
