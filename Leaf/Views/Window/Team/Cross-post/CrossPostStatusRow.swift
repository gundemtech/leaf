//
//  CrossPostStatusRow.swift
//  Leaf
//
//  Track 5 / S6 T12 — one row per requested channel rendered in the
//  Send sheet's `.sent` state. Three input variants:
//   - Leaf (always green check; we got here because the DM persisted).
//   - Slack (success/failure copy from CrossPostHumanMessage.text).
//   - Linear (success/failure copy from CrossPostHumanMessage.text).
//
//  Layout: leading SF Symbol (success/warning) + status text + optional
//  secondary detail (push delivery, retry-after, identifier link). Uses
//  LeafColor.status tokens — no hard-coded fills.
//

import SwiftUI
import LeafCore

struct CrossPostStatusRow: View {
    enum Tone {
        case success
        case warning

        var color: Color {
            switch self {
            case .success: return LeafColor.status.success
            case .warning: return LeafColor.status.warning
            }
        }

        var symbolName: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    let tone: Tone
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
            Image(systemName: tone.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if let detail {
                    Text(detail)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Helpers

extension CrossPostStatusRow {
    /// Always-success row for the Leaf E2E channel — we only reach this row
    /// when the DM persisted server-side; recipient delivery semantics live
    /// in `PushDispatchStatus`, surfaced as `detail`.
    static func leaf(
        recipientDisplayName: String,
        pushStatus: SentDirectMessage.PushDispatchStatus
    ) -> CrossPostStatusRow {
        let detail: String?
        switch pushStatus {
        case .sent:
            detail = "Push delivered to recipient device."
        case .skipped:
            detail = "No push (notify off). Recipient will see on next inbox poll."
        case .failed(let reason):
            detail = "Push deferred: \(reason). Message persisted."
        }
        return CrossPostStatusRow(
            tone: .success,
            title: "Sent to \(recipientDisplayName) (Leaf)",
            detail: detail
        )
    }

    static func slack(_ result: SlackCrossPostResult) -> CrossPostStatusRow {
        CrossPostStatusRow(
            tone: result.ok ? .success : .warning,
            title: CrossPostHumanMessage.text(for: result)
        )
    }

    static func linear(_ result: LinearCrossPostResult) -> CrossPostStatusRow {
        CrossPostStatusRow(
            tone: result.ok ? .success : .warning,
            title: CrossPostHumanMessage.text(for: result)
        )
    }
}
