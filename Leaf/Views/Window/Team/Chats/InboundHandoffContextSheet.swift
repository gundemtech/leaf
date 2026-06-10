//
//  InboundHandoffContextSheet.swift
//  Leaf
//
//  AI-UI-3 — recipient-side "Context for me": quotes the inbound handoff,
//  states EXACTLY what will leave (the message + a body-free summary of own
//  activity), explicit confirm, answer in place. Local DI (@State reader).
//

import LeafCore
import SwiftUI

struct InboundHandoffContextSheet: View {
  let row: DirectMessageMirrorRow

  @Environment(WindowState.self) private var windowState
  @Environment(\.dismiss) private var dismiss
  @State private var reader = InboundHandoffContextReader()

  /// Exact-match CTA for the missing-key failure (pattern: AskLeafView).
  private static let missingKeyMessage = AIWorkAnswerer.message(for: .missingAPIKey)

  var body: some View {
    LeafSheetLayout(title: "Context for me", onDismiss: { dismiss() }) {
      VStack(alignment: .leading, spacing: LeafSpace.lg) {
        // The note being analyzed — already visible in the thread; quoted for consent.
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
          Text("\(row.senderDisplayName)'s handoff")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
          Text(row.body)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .lineLimit(6)
            .padding(LeafSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LeafColor.surface.inset, in: RoundedRectangle(cornerRadius: LeafRadius.sm))
        }
        Text(
          "Sends this message and a body-free summary of your own recent activity "
            + "(last 7 days) to your AI. The answer stays on this Mac. "
            + "Every send is logged to AI privacy (Settings → Sharing)."
        )
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.tertiary)
        content
        Spacer(minLength: 0)
        footer
      }
    }
    .frame(minWidth: 440, minHeight: 320)
    .onAppear { reader.reset() }
  }

  @ViewBuilder
  private var content: some View {
    switch reader.state {
    case .idle:
      EmptyView()
    case .loading:
      HStack(spacing: LeafSpace.sm) {
        ProgressView().controlSize(.small)
        Text("Thinking…")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
      }
    case .answered(let text):
      ScrollView {
        Text(text)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)
    case .error(let message):
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text(message)
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.status.warning)
        if message == Self.missingKeyMessage {
          Button("Open Settings") {
            windowState.section = .settings
            dismiss()
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Close") { dismiss() }
        .buttonStyle(.plain)
        .foregroundStyle(LeafColor.text.tertiary)
      Spacer()
      switch reader.state {
      case .idle, .error:
        Button("Get context") {
          Task {
            await reader.explain(
              handoffText: row.body, senderName: row.senderDisplayName,
              sentAtMs: row.serverCreatedAtMs)
          }
        }
      case .loading, .answered:
        EmptyView()
      }
    }
  }
}
