//
//  Stepper.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

struct HorizontalStepper: View {
    let steps: [FlowStep]
    let current: FlowStep
    let onSelect: (FlowStep) -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                StepNode(index: idx + 1,
                         step: step,
                         state: state(for: step))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(step) }

                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Theme.accent : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func state(for step: FlowStep) -> StepNode.State {
        if step == current { return .active }
        return step.rawValue < current.rawValue ? .done : .pending
    }
}

private struct StepNode: View {
    enum State { case done, active, pending }
    let index: Int
    let step: FlowStep
    let state: State

    var body: some View {
        HStack(spacing: Space.s) {
            ZStack {
                Circle().fill(circleFill).frame(width: 26, height: 26)
                Group {
                    switch state {
                    case .done: Image(systemName: "checkmark")
                    default:    Text("\(index)")
                    }
                }
                .font(.caption.weight(.bold))
                // FIX: paksa Color di kedua sisi ternary (‘.white’ tak ada di HierarchicalShapeStyle)
                .foregroundStyle(state == .pending ? Color.secondary : Color.white)
            }
            Text(step.title)
                .font(.callout.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
                .fixedSize()
        }
    }

    private var circleFill: Color {
        state == .pending ? Color.primary.opacity(0.1) : Theme.accent
    }
}
