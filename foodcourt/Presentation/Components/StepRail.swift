//
//  Components.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct StepRail: View {
    let steps: [FlowStep]
    let current: FlowStep
    let onSelect: (FlowStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Theme.accent)
                Text("Prism")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .spad(Space.l, [.horizontal, .top])
            .padding(.bottom, Space.m)

            ForEach(steps) { step in
                StepRow(step: step,
                        state: state(for: step))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(step) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func state(for step: FlowStep) -> StepRow.State {
        if step == current { return .active }
        return step.rawValue < current.rawValue ? .done : .pending
    }
}

struct StepRow: View {
    enum State { case done, active, pending }
    let step: FlowStep
    let state: State

    var body: some View {
        HStack(spacing: Space.s) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 26, height: 26)
                Group {
                    switch state {
                    case .done:   Image(systemName: "checkmark")
                    default:      Image(systemName: step.systemImage)
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(iconColor)
            }
            Text(step.title)
                .font(.callout.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(state == .active ? Theme.accentSoft : .clear)
        )
        .padding(.horizontal, Space.s)
    }

    private var circleFill: Color {
        switch state {
        case .done:    return Theme.accentFill
        case .active:  return Theme.accentFill
        case .pending: return Color.primary.opacity(0.1)
        }
    }
    private var iconColor: Color {
        state == .pending ? .secondary : Theme.onAccent
    }
}
