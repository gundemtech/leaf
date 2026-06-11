//
//  WorkspaceHubHeader.swift
//  Team → Workspace Hub — page header: colored square workspace mark
//  (LeafWorkspaceMark, same identity visual as the sidebar picker) +
//  workspace name + "N members · created <date>" subtitle + trailing
//  «+ Invite teammate» primary CTA (⌘N — the app's only ⌘N registration;
//  the header is mounted on every hub tab so the shortcut works
//  everywhere on the page). Name is read-only here — rename lives in the
//  hub Settings tab.
//

import LeafCore
import SwiftUI

struct WorkspaceHubHeader: View {
  let active: Workspace
  let memberCount: Int
  let onInvite: () -> Void

  var body: some View {
    HStack(spacing: LeafWorkspaceHubTokens.headerSpacing) {
      LeafWorkspaceMark(
        name: active.name,
        seed: active.id,
        size: LeafWorkspaceHubTokens.headerMarkSize
      )
      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        Text(active.name)
          .font(LeafType.title.medium)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
        Text(
          WorkspaceHubPresentation.subtitle(
            memberCount: memberCount, createdAt: active.createdAt)
        )
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
      }
      Spacer(minLength: 0)
      // Round 8 — create/new/generate/invite CTAs styled identically
      // (primary .md) across the app.
      LeafButton("+ Invite teammate", variant: .primary, size: .md) {
        onInvite()
      }
      .keyboardShortcut("n", modifiers: .command)
    }
  }
}
