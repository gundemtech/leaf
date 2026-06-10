//
//  MembersTab.swift
//  Team → Workspace Hub — Members tab. Roster + invite management in one
//  place: member admin list (tap → DM composer), pending join requests
//  (M027 admin queue), active invite tokens, legacy S3 pending invites
//  (self-hides when empty; deprecates ≤30d post-ship).
//
//  Sections are the same structs that lived under Settings → Workspace —
//  each carries its own `.task(id: activeWorkspaceID)` refresh, so a
//  sidebar workspace switch while this tab is mounted re-fetches for free.
//

import LeafCore
import SwiftUI

struct MembersTab: View {
  /// Non-self member row tap → SendDirectMessageSheet (owned by TeamView).
  let onTapMember: (TeamMember) -> Void

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: LeafSpace.xl) {
        WorkspaceMembersAdminList(onTapMember: onTapMember)
        PendingRequestsSection()  // M027 invite-redesign — admin queue
        ActiveTokensSection()  // M027 invite-redesign — admin token mgmt
        PendingInvitesSection()  // S3 legacy back-compat (deprecates ≤30d post-ship)
      }
      .padding(.bottom, LeafSpace.md)
    }
  }
}
