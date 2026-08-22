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
    let isLocked: Bool
    /// Per-step gate: a step that returns false is dimmed and cannot be tapped.
    let isEnabled: (FlowStep) -> Bool
    let onSelect: (FlowStep) -> Void

    init(
        steps: [FlowStep],
        current: FlowStep,
        isLocked: Bool = false,
        isEnabled: @escaping (FlowStep) -> Bool = { _ in true },
        onSelect: @escaping (FlowStep) -> Void
    ) {
        self.steps = steps
        self.current = current
        self.isLocked = isLocked
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                StepNode(index: idx + 1,
                         step: step,
                         state: state(for: step))
                    .opacity(isEnabled(step) ? 1 : 0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { if isEnabled(step) { onSelect(step) } }
                    .allowsHitTesting(isEnabled(step))
                    .help(isEnabled(step) ? "" : "Import a video first.")

                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Theme.accentFill : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .opacity(isLocked ? 0.62 : 1)
        .disabled(isLocked)
        .accessibilityHint(isLocked ? "Navigation is locked until the analysis finishes." : "")
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
                .foregroundStyle(state == .pending ? Color.secondary : Theme.onAccent)
            }
            Text(step.title)
                .font(.callout.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
                .fixedSize()
        }
    }

    private var circleFill: Color {
        state == .pending ? Color.primary.opacity(0.1) : Theme.accentFill
    }
}
