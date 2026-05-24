import Foundation
import Observation
import SwiftUI

enum WindowSection: String, CaseIterable, Hashable, Codable, Identifiable {
    case home, activity, analytics, team, connections, settings, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         "Home"
        case .activity:     "Activity"
        case .analytics:    "Analytics"
        case .team:         "Team"
        case .connections:  "Connections"
        case .settings:     "Settings"
        case .profile:      "Profile"
        }
    }

    /// Asset Catalog name (Figma SVG, template-rendered) for sections with
    /// a custom glyph. All nav sections use Asset Catalog icons.
    var icon: String {
        switch self {
        case .home:         LeafIcons.nav.home
        case .activity:     LeafIcons.nav.activity
        case .analytics:    LeafIcons.nav.activity
        case .team:         LeafIcons.nav.team
        case .connections:  LeafIcons.nav.connections
        case .settings:     LeafIcons.nav.settings
        case .profile:      LeafIcons.nav.profile
        }
    }

    /// True when `icon` is an SF Symbol (system rendering); false when it
    /// is an Asset Catalog name (template-rendered). All current sections
    /// use Asset Catalog icons — SF Symbol rendering is no longer needed.
    var iconIsSystem: Bool { false }
}

@MainActor
@Observable
final class WindowState {
    var section: WindowSection = .home

    /// Track 5 / S7 H.6 — Deep-link target for "scroll to specific DM" after the
    /// user clicks an APNs notification. LeafAppDelegate populates this from
    /// `userInfo["leaf_message_id"]`; TeamView observes via `.onChange` and
    /// scrolls/highlights the matching cell, then clears the value to nil.
    var pendingMessageID: String?

    /// Track 5 / S7 H.6 — Workspace activation target set alongside
    /// `pendingMessageID`. LeafAppDelegate first switches the active workspace
    /// (via ActiveWorkspaceStore.setActive), then sets this for the UI to
    /// confirm/observe (e.g., for transient debugging surfaces).
    var pendingWorkspaceID: String?

    /// Track 5 / S8 T6 — APNs `dm.reply` action toggles this `true` after the
    /// deep-link plumbing (workspace switch + section = .team + pendingMessageID)
    /// finishes. TeamView observes via `.onChange`, scrolls to `pendingMessageID`
    /// + signals reply-focus intent, then clears the flag back to `false`.
    /// Pure transient signal — never persisted, never read concurrently.
    var focusReplyField: Bool = false

    /// M027 invite-redesign — link-click entry. InviteURLHandler detects the new
    /// `leaf://invite/LEAF-XXXX-XXXX-XXXX` format and sets this to the bare code.
    /// RootView observes + presents JoinWorkspaceByCodeSheet pre-filled with the
    /// code (skipping the paste step). Cleared by the sheet on dismiss.
    var pendingInviteCode: String?

    /// M027 invite-redesign — true after invitee submits a join request via the
    /// JoinWorkspaceByCodeSheet. RootView observes + presents JoinRequestWaitingCard
    /// which 30s-polls JoinRequestsReader.pollOwn until terminal state.
    var joinRequestWaitingPresented: Bool = false
}
