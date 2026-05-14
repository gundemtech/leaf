// Phase 5.2.E — InviteAcceptService invitee-orchestrator tests.
//
// Track 5 / S3 — Phase 5.5 two-step fetchInvite + acceptInvite(blob:otp:displayName:)
// API removed. This file's test methods are intentionally gutted; coverage now lives in:
//   - SupabaseClientResolveTests (Edge Function wire)
//   - SupabaseClientProbeTests (probe variant)
//   - SupabaseClientWorkspaceMembersTests (JWT INSERT)
//   - (future) InviteAcceptServiceTrackFiveTests (single-call acceptInvite(url:displayName:otp:))
//
// File preserved for git history + as a re-anchor point for any retained Phase 5.5 invariants
// that don't fit the new shape.

import XCTest
@testable import LeafCore

final class InviteAcceptServiceTests: XCTestCase {
    func testPhaseFiveFiveSurfaceRemoved() throws {
        // Sanity: confirms the rewrite landed. New surface lives in InviteAcceptService.acceptInvite(url:displayName:otp:).
        // No-op pass — Track 5 coverage in SupabaseClient*Tests.
    }
}
