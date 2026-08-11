//
//  SideBar.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//
import SwiftUI

struct SideMenu: View {
    let current: AppSection
    let onSelect: (AppSection) -> Void
 
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(Theme.accent)
                Text("Foodcourt")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .spad(Space.l, [.horizontal, .top])
            .padding(.bottom, Space.l)
 
            FieldLabel(text: "Menu")
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xs)
 
            ForEach([AppSection.newAnalysis, .history, .chat], id: \.self) { section in
                MenuRow(section: section, isActive: section == current)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(section) }
            }
 
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}
 
private struct MenuRow: View {
    let section: AppSection
    let isActive: Bool
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: section.systemImage)
                .frame(width: 22)
                .foregroundStyle(isActive ? Theme.accent : .secondary)
            Text(section.title)
                .font(.callout.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(isActive ? Theme.accentSoft : .clear)
        )
        .padding(.horizontal, Space.s)
    }
}
