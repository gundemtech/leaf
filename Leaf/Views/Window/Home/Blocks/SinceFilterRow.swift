//
//  SinceFilterRow.swift
//  Track-10 T5 — file-local chip strip for SINCE YOU WERE LAST ACTIVE block.
//  5 chips: [All] / [Linear] / [GitHub] / [Slack] / [Detections] each with per-
//  chip count suffix. Selected chip uses `.accent` tone, others `.neutral`.
//
//  Q8 dual-ship discipline: NOT extracted to a generic LeafFilterChipStrip<T>
//  primitive yet — rule-of-three carry C-T5-2 waits for the 3rd similar strip
//  (T6 TEAM·N or T8 standup) to drive extraction with real signal.
//

import LeafCore
import SwiftUI

enum SinceFilter: String, CaseIterable, Hashable {
    case all
    case linear
    case github
    case slack
    case detection

    var label: String {
        switch self {
        case .all: "All"
        case .linear: "Linear"
        case .github: "GitHub"
        case .slack: "Slack"
        case .detection: "Detections"
        }
    }

    func admits(_ source: SinceSource) -> Bool {
        switch self {
        case .all: return true
        case .linear: return source == .linear
        case .github: return source == .github
        case .slack: return source == .slack
        case .detection: return source == .detection
        }
    }
}

struct SinceFilterRow: View {
    @Binding var selected: SinceFilter
    let counts: [SinceFilter: Int]

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            ForEach(SinceFilter.allCases, id: \.self) { filter in
                let count = counts[filter] ?? 0
                Button {
                    selected = filter
                } label: {
                    LeafPill(
                        title: "\(filter.label) · \(count)",
                        tone: selected == filter ? .accent : .neutral
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(filter.label) filter, \(count) \(count == 1 ? "item" : "items")")
                .accessibilityAddTraits(
                    selected == filter ? [.isButton, .isSelected] : .isButton
                )
            }
        }
    }
}
