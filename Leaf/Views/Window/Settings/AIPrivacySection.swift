//
//  AIPrivacySection.swift
//  Leaf
//
//  AI-UI-2 — секция «AI privacy» в Settings → Sharing: две append-only ленты
//  reverse-аудита AI-egress. «AI received» — каждая bodies-эскалация (M031,
//  пишется audit-first до POST); «AI handoffs» — каждый AI-черновик, ушедший
//  коллеге E2E (M032, пишется at-send). Только metadata/refs/own-excerpts —
//  тел в таблицах структурно нет.
//

import LeafCore
import SwiftUI

struct AIPrivacySection: View {
  @State private var reader = AIPrivacyFeedsReader()

  var body: some View {
    LeafSection(
      title: "AI privacy",
      description: "Append-only log of what has been sent to AI models: event texts you explicitly escalated, and AI-drafted handoffs sent to teammates."
    ) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        switch reader.state {
        case .loading:
          HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text("Reading the log…")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        case .error(let msg):
          Text(msg)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.status.warning)
        case .loaded(let escalations, let handoffs):
          escalationsCard(escalations)
          handoffsCard(handoffs)
        }
      }
    }
    .task { await reader.refresh() }
  }

  // MARK: - AI received (escalations, M031)

  @ViewBuilder
  private func escalationsCard(_ rows: [AIPrivacyFeedPresentation.EscalationRow]) -> some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text("AI received")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
        if rows.isEmpty {
          Text("Nothing sent to AI yet. Event texts only leave this Mac when you confirm an escalation.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
              escalationRow(row)
                .padding(.vertical, LeafSpace.xs)
              if row.id != rows.last?.id {
                LeafDivider(style: .soft)
              }
            }
          }
        }
      }
    }
  }

  private func escalationRow(_ row: AIPrivacyFeedPresentation.EscalationRow) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
      HStack(spacing: LeafSpace.sm) {
        Text(row.at, format: .dateTime.day().month().hour().minute())
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
        Text(row.model)
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
        Text("\(row.eventCount) event\(row.eventCount == 1 ? "" : "s")")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
        Spacer()
      }
      if let q = row.question, !q.isEmpty {
        Text("“\(q)”")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(2)
      }
    }
  }

  // MARK: - AI handoffs (M032)

  @ViewBuilder
  private func handoffsCard(_ rows: [AIPrivacyFeedPresentation.HandoffRow]) -> some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text("AI handoffs")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
        if rows.isEmpty {
          Text("No AI-drafted handoffs yet. Drafts are logged here when they are sent to a teammate.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
              handoffRow(row)
                .padding(.vertical, LeafSpace.xs)
              if row.id != rows.last?.id {
                LeafDivider(style: .soft)
              }
            }
          }
        }
      }
    }
  }

  private func handoffRow(_ row: AIPrivacyFeedPresentation.HandoffRow) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
      HStack(spacing: LeafSpace.sm) {
        Text(row.at, format: .dateTime.day().month().hour().minute())
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
        Text("→ \(row.recipientName)")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
        Text("\(row.model) · \(row.factCount) facts")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
        if row.crosspostedSlack {
          crosspostBadge("Slack")
        }
        if row.crosspostedLinear {
          crosspostBadge("Linear")
        }
        Spacer()
      }
      if let topic = row.topic, !topic.isEmpty {
        Text("“\(topic)”")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(2)
      }
    }
  }

  private func crosspostBadge(_ label: String) -> some View {
    Text(label)
      .font(LeafType.body.small)
      .foregroundStyle(LeafColor.text.tertiary)
      .padding(.horizontal, LeafSpace.xs)
      .background(LeafColor.surface.inset, in: Capsule())
  }
}
