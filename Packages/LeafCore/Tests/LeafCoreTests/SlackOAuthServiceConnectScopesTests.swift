//
//  SlackOAuthServiceConnectScopesTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — Task 10. Scope-parameter sanity for the
//  `connect(scopes:)` overload landed in `Leaf/Integrations/Slack/SlackOAuthService.swift`.
//
//  Note: `SlackOAuthService` itself lives in the Leaf app target (mirror
//  GitHubOAuthService), so the `.connectedScopeOutdated` enum case is verified
//  by the xcodebuild Leaf scheme build downstream (ConnectionsView's exhaustive
//  switch must compile). Here we cover the LeafCore-side surface: the
//  `SlackOAuthEndpoints.requestedScopeParameter()` helper agrees with
//  `SlackScopesService.requested()` byte-for-byte (comma-separated form,
//  Slack `user_scope` shape).
//

import XCTest

@testable import LeafCore

final class SlackOAuthServiceConnectScopesTests: XCTestCase {
    func testRequestedScopeParameterMatchesSlackScopesService() {
        XCTAssertEqual(
            SlackOAuthEndpoints.requestedScopeParameter(),
            SlackScopesService.requested().joined(separator: ",")
        )
    }

    func testRequestedScopeParameterIsCommaSeparated() {
        // Slack's authorize URL uses comma-separated user_scope (NOT space —
        // в отличие от GitHub Device Flow `scope` param).
        let param = SlackOAuthEndpoints.requestedScopeParameter()
        XCTAssertFalse(param.contains(" "))
        XCTAssertTrue(param.contains(","))
    }

    func testRequestedScopeParameterIncludesRequiredCoreAndOptional() {
        let param = SlackOAuthEndpoints.requestedScopeParameter()
        let tokens = Set(param.split(separator: ",").map { String($0) })
        XCTAssertTrue(SlackScopesService.requiredCore.isSubset(of: tokens))
        XCTAssertTrue(SlackScopesService.requiredOptional.isSubset(of: tokens))
    }
}
