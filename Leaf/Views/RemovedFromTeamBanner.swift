//
//  RemovedFromTeamBanner.swift
//  Leaf
//
//  Phase 5.3.E — full-screen takeover when the local device's team_member row
//  is marked removed (admin removed this peer; tombstone applied by
//  RotationFetchService). Info-only banner; wipe-local-data action — out of
//  MVP per spec §15.
//

import SwiftUI

struct RemovedFromTeamBanner: View {
    let orgName: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.leafAccent)
            VStack(spacing: 12) {
                Text("You've been removed from \(orgName)")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
                Text("Your local data remains on this device, but you can no longer send presence to teammates. To start fresh, wipe local team data via Settings (coming soon).")
                    .font(.leafBody)
                    .foregroundStyle(.leafInk.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 480)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.leafBackground.ignoresSafeArea())
    }
}
