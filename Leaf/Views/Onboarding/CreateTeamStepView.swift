//
//  CreateTeamStepView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding `.team` admin path: enter display name → calls
//  OrgReader.createPersonalOrg(displayName:). On success, the caller (OnboardingView)
//  advances to `.done` via .onChange.
//
//  Track 2 / D4 — migrated to D1 atoms.
//

import LeafCore
import SwiftUI

struct CreateTeamStepView: View {
  @Environment(WorkspaceReader.self) private var workspaceReader
  @State private var displayName: String = ""
  @State private var submitted: Bool = false
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LeafSpace.md) {
      Text("Create new team")
        .font(LeafType.title.small)
        .foregroundStyle(LeafColor.text.primary)
      Text("Pick how you'll show up to your teammates. You can invite them right after.")
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: LeafSpace.xs) {
        Text("YOUR DISPLAY NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
        TextField("e.g. Sasha", text: $displayName)
          .textFieldStyle(.roundedBorder)
          .font(LeafType.body.regular)
          .disabled(submitted)
      }

      HStack {
        LeafButton("Back", variant: .ghost, size: .sm, action: onCancel)
        Spacer()
        LeafButton(
          "Create",
          variant: .primary,
          size: .sm,
          isLoading: submitted,
          action: {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            submitted = true
            Task { @MainActor in
              // Onboarding only ever hits the fresh-install path
              // — no existing workspaces to collide with — so the
              // returned error string here is purely defensive
              // (server-sync failure surfaces in a follow-up
              // toast / log; sheet stays open).
              _ = await workspaceReader.createWorkspace(displayName: trimmed)
              submitted = false
            }
          }
        )
        .disabled(submitted || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .onAppear {
      if displayName.isEmpty {
        displayName = NSFullUserName()
      }
    }
  }
}
