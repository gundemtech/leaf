//
//  JoinWorkspaceByCodeSheet.swift
//  Leaf
//
//  M027 invite-redesign — invitee path B (paste-code entry).
//  Sheet → paste `LEAF-XXXX-XXXX-XXXX` code → JoinCode.verifyChecksum
//  client-side typo detection → JoinRequestWaitingCard.
//

import LeafCore
import SwiftUI

struct JoinWorkspaceByCodeSheet: View {
  @Environment(InviteURLHandler.self) private var urlHandler
  @Environment(WindowState.self) private var windowState
  @Environment(\.dismiss) private var dismiss

  @State private var codeInput: String = ""
  @State private var errorMessage: String?
  @State private var displayName: String = NSFullUserName()
  @State private var step: Step = .pasteCode
  /// Local one-shot guard so a trackpad bounce / double-tap in the 1-2 ms
  /// before `dismiss()` takes effect doesn't queue two `handleCodePaste`
  /// dispatches and create two server-side `join_requests` for the same
  /// code. `JoinRequestsReader` also gates server-side via `isSubmitInFlight`
  /// — this is belt-and-suspenders at the UI surface.
  @State private var submitFired: Bool = false

  enum Step {
    case pasteCode  // initial — paste + Continue
    case enterName  // verified code → ask for display name + Send request
  }

  var body: some View {
    LeafSheetLayout(title: "Join workspace by code", onDismiss: { dismiss() }) {
      VStack(alignment: .leading, spacing: LeafSpace.lg) {
        switch step {
        case .pasteCode: pasteCodeStep
        case .enterName: enterNameStep
        }
        Spacer(minLength: 0)
        footer
      }
    }
    .onAppear {
      // Pre-fill from link-click entry — InviteURLHandler.handle sets
      // WindowState.pendingInviteCode when a M027 leaf://invite/LEAF-...
      // deep-link is opened. Do NOT clear pendingInviteCode here — it's
      // the only true-term in Sidebar's sheet binding on this entry path
      // (`joinByCodePresented || pendingInviteCode != nil`); clearing it
      // mid-flow flips the getter false and self-dismisses the sheet on
      // the next render. The binding's `set` closure clears it on
      // user-initiated dismiss.
      if let prefilled = windowState.pendingInviteCode {
        codeInput = prefilled
        step = .enterName
      }
    }
  }

  @ViewBuilder
  private var pasteCodeStep: some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        Text("PASTE CODE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
        TextField("LEAF-XXXX-XXXX-XXXX", text: $codeInput)
          .textFieldStyle(.roundedBorder)
          .font(LeafType.mono.regular)
          .onChange(of: codeInput) { _, newValue in
            // Auto-format `LEAF-XXXX-XXXX-XXXX` as user types:
            // uppercase + strip whitespace/illegal-alphabet chars
            // (drops I/L/O/U/0/1) + auto-insert dashes + cap at 19.
            // No-op-write guard prevents @State write loop.
            let formatted = JoinCode.format(newValue)
            if formatted != newValue { codeInput = formatted }
            errorMessage = nil
          }

        Text(
          "Codes look like LEAF-A8X7-B3K9-Q2N4. Anyone with a valid code can submit a request — the admin still needs to approve."
        )
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)

        if let err = errorMessage {
          LeafBanner(tone: .danger, title: err, description: nil, density: .compact)
        }
      }
    }
  }

  @ViewBuilder
  private var enterNameStep: some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        Text("CODE VERIFIED").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
        Text(codeInput)
          .font(LeafType.mono.regular)
          .foregroundStyle(LeafColor.text.primary)

        Text("YOUR DISPLAY NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
        TextField("e.g. Bob Smith", text: $displayName)
          .textFieldStyle(.roundedBorder)

        Text(
          "This is how the admin sees you in the queue. The admin reviews and approves before you join."
        )
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
      }
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack {
      LeafButton("Cancel", variant: .secondary, size: .md) { dismiss() }
      Spacer()
      switch step {
      case .pasteCode:
        LeafButton("Continue", variant: .primary, size: .md) {
          verifyAndAdvance()
        }
        .disabled(codeInput.isEmpty)
      case .enterName:
        LeafButton("Send request", variant: .primary, size: .md) {
          submitRequest()
        }
        .disabled(
          submitFired ||
          displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
  }

  // MARK: - Helpers

  private func verifyAndAdvance() {
    let trimmed = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard JoinCode.verifyChecksum(trimmed) else {
      errorMessage = "Invalid code. Check for typos and try again."
      return
    }
    codeInput = trimmed
    step = .enterName
  }

  private func submitRequest() {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !submitFired else { return }
    submitFired = true
    // Route through InviteURLHandler so the waiting-card UI gets a consistent
    // path with the link-click entry (both submit via JoinRequestsReader.submit).
    urlHandler.handleCodePaste(code: codeInput, displayName: trimmedName)
    dismiss()
  }
}
