//
//  ProfileDangerZone.swift
//  Leaf
//
//  Profile "Danger zone" — native confirmationDialog → onDelete. onDelete
//  returns an error string on failure (nil = success; the gate re-arm from
//  sign-out tears down this view). Mirrors the web dashboard's delete affordance.
//

import LeafCore
import SwiftUI

struct ProfileDangerZone: View {
  /// Returns nil on success, or an error message to display in-card on failure.
  let onDelete: () async -> String?

  @State private var confirming = false
  @State private var inFlight = false
  @State private var errorText: String?

  var body: some View {
    LeafSection(title: "Danger zone", description: "Permanently delete your Leaf account.") {
      LeafCard(variant: .raised, padding: .regular) {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
          Text(
            "Deleting your account is permanent. Your team memberships and identity "
              + "key are removed and you're signed out on this Mac."
          )
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)

          if let errorText {
            Text(errorText)
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.status.danger)
          }

          HStack {
            Spacer(minLength: 0)
            LeafButton(
              inFlight ? "Deleting…" : "Delete account", variant: .destructive, size: .sm
            ) { confirming = true }
            .disabled(inFlight)
          }
        }
      }
    }
    .confirmationDialog(
      "Delete account?", isPresented: $confirming, titleVisibility: .visible
    ) {
      Button("Delete account", role: .destructive) { Task { await runDelete() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes your account and signs you out. This can't be undone.")
    }
  }

  private func runDelete() async {
    inFlight = true
    errorText = nil
    errorText = await onDelete()  // nil → success (gate takes over)
    inFlight = false
  }
}
