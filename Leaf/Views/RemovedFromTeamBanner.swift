//
//  RemovedFromTeamBanner.swift
//  Phase 5.3.E — full-screen takeover when the local device's team_member row
//  is marked removed.
//
//  Track 2 / D4 — migrated to LeafEmptyState (hero icon + dynamic orgName title +
//  description). Wipe-local-data action remains out-of-MVP (info-only).
//

import SwiftUI

struct RemovedFromTeamBanner: View {
    let orgName: String

    var body: some View {
        LeafEmptyState(
            icon: LeafIcons.object.userError,
            title: "You've been removed from \(orgName)",
            description:
                "Your local data remains on this device, but you can no longer send presence to teammates. To start fresh, wipe local team data via Settings (coming soon)."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LeafColor.surface.canvas.ignoresSafeArea())
    }
}
