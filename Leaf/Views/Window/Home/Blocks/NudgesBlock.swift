//
//  NudgesBlock.swift
//  UC-2 — "am I quietly stuck?" card. Renders only when nudges exist;
//  the footer states the privacy contract verbatim from the landing:
//  visible only to you, no manager dashboard. Rows open their source
//  (PR / issue) when a URL resolved; otherwise informational.
//

import AppKit
import LeafCore
import SwiftUI

struct NudgesBlock: View {
    let nudges: [NudgeItem]

    var body: some View {
        if !nudges.isEmpty {
            // Track B-UI — terminal-card chrome matching the landing mockup:
            // "● you · last 24h" header + warning count badge + verbatim
            // privacy footer.
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    LeafTerminalCardHeader(dotTone: .success, title: "you · last 24h") {
                        LeafStatusBadge(
                            text: "\(nudges.count) NUDGE\(nudges.count == 1 ? "" : "S")",
                            tone: .warning)
                    }
                    ForEach(nudges) { nudge in
                        row(nudge)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Text("visible only to you · no manager dashboard")
                            .font(LeafType.mono.small)
                            .foregroundStyle(LeafColor.text.quaternary)
                    }
                    .padding(.top, LeafSpace.xs)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: nudges)
        }
    }

    @ViewBuilder
    private func row(_ nudge: NudgeItem) -> some View {
        Button {
            if let url = nudge.sourceURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                Image(systemName: "exclamationmark")
                    .font(LeafType.body.small.bold())
                    .foregroundStyle(LeafColor.status.warning)
                    .padding(.top, LeafSpace.xxs)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(nudge.title)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(2)
                    if let detail = nudge.detail, !detail.isEmpty {
                        Text(detail)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                            .lineLimit(1)
                    }
                    if !nudge.extraLines.isEmpty {
                        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                            ForEach(nudge.extraLines, id: \.self) { line in
                                Text(line)
                                    .font(LeafType.body.small)
                                    .foregroundStyle(LeafColor.text.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, LeafSpace.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel(nudge))
        .accessibilityAddTraits(nudge.sourceURL == nil ? [] : .isButton)
    }

    private func a11yLabel(_ nudge: NudgeItem) -> String {
        let detail = nudge.detail.map { ", \($0)" } ?? ""
        let action = nudge.sourceURL == nil ? "" : ", tap to open"
        return "Nudge: \(nudge.title)\(detail)\(action)"
    }
}
