import XCTest

@testable import LeafCore

final class SlackScopesServiceTests: XCTestCase {
    func testRequiredCoreContainsHistoryAndReadFamilies() {
        XCTAssertEqual(SlackScopesService.requiredCore.count, 13)
        XCTAssertTrue(SlackScopesService.requiredCore.contains("users:read"))
        XCTAssertTrue(SlackScopesService.requiredCore.contains("files:read"))
        // *:history family — conversations.history etc.
        for scope in ["channels:history", "groups:history", "im:history", "mpim:history"] {
            XCTAssertTrue(SlackScopesService.requiredCore.contains(scope), "\(scope) missing")
        }
        // *:read family — users.conversations needs at least one of these;
        // requesting all four covers public + private + DM + group-DM listings
        // (C2 anti-regression — without these `slack_channel_joined/_left`
        // never fire because the membership snapshot is never written).
        for scope in ["channels:read", "groups:read", "im:read", "mpim:read"] {
            XCTAssertTrue(SlackScopesService.requiredCore.contains(scope), "\(scope) missing")
        }
    }

    func testRequiredOptionalNineScopes() {
        XCTAssertEqual(SlackScopesService.requiredOptional.count, 9)
        XCTAssertTrue(SlackScopesService.requiredOptional.contains("reactions:read"))
        XCTAssertTrue(SlackScopesService.requiredOptional.contains("canvases:read"))
        // chat.scheduledMessages.list requires chat:write — must match the
        // SlackWarmCollector scope gate (C1 anti-regression).
        XCTAssertTrue(SlackScopesService.requiredOptional.contains("chat:write"))
        XCTAssertFalse(SlackScopesService.requiredOptional.contains("chat:read"))
    }

    func testRequestedReturnsUnionSorted() {
        let requested = SlackScopesService.requested()
        XCTAssertEqual(requested.count, 22)  // 13 core + 9 optional
        XCTAssertEqual(requested, requested.sorted(), "Must be sorted (deterministic)")
    }

    func testMissingEmptyWhenAllCoreGranted() async {
        let granted: Set<String> = SlackScopesService.requiredCore
        let svc = SlackScopesService(grantedOverride: granted)
        let missing = await svc.missing()
        XCTAssertTrue(missing.isEmpty)
    }

    func testMissingDetectsCoreGap() async {
        var granted: Set<String> = SlackScopesService.requiredCore
        granted.remove("dnd:read")
        let svc = SlackScopesService(grantedOverride: granted)
        let missing = await svc.missing()
        XCTAssertEqual(missing, ["dnd:read"])
    }

    func testMissingOptionalDetectsOptionalGap() async {
        let granted: Set<String> = SlackScopesService.requiredCore
        let svc = SlackScopesService(grantedOverride: granted)
        let missing = await svc.missingOptional()
        XCTAssertEqual(missing, SlackScopesService.requiredOptional)
    }

    func testHasPredicate() async {
        let svc = SlackScopesService(grantedOverride: ["users:read"])
        let yes = await svc.has("users:read")
        let no = await svc.has("canvases:read")
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
    }

    func testParseScopeStringCommaSeparated() {
        let parsed = SlackScopesService.parseScopeString("users:read,users.profile:read,search:read")
        XCTAssertEqual(parsed, ["users:read", "users.profile:read", "search:read"])
    }

    func testParseScopeStringSpaceSeparated() {
        let parsed = SlackScopesService.parseScopeString("users:read users.profile:read search:read")
        XCTAssertEqual(parsed, ["users:read", "users.profile:read", "search:read"])
    }

    func testParseScopeStringMixedCommaSpaceTrimmed() {
        let parsed = SlackScopesService.parseScopeString("  users:read , users.profile:read \t search:read,")
        XCTAssertEqual(parsed, ["users:read", "users.profile:read", "search:read"])
    }

    func testParseScopeStringEmpty() {
        XCTAssertEqual(SlackScopesService.parseScopeString(""), [])
        XCTAssertEqual(SlackScopesService.parseScopeString("   "), [])
        XCTAssertEqual(SlackScopesService.parseScopeString(","), [])
    }
}
