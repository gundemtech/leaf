import XCTest
@testable import LeafCore

final class SlackScopesServiceTests: XCTestCase {
    func testRequiredCoreNineScopes() {
        XCTAssertEqual(SlackScopesService.requiredCore.count, 9)
        XCTAssertTrue(SlackScopesService.requiredCore.contains("users:read"))
        XCTAssertTrue(SlackScopesService.requiredCore.contains("files:read"))
    }

    func testRequiredOptionalNineScopes() {
        XCTAssertEqual(SlackScopesService.requiredOptional.count, 9)
        XCTAssertTrue(SlackScopesService.requiredOptional.contains("reactions:read"))
        XCTAssertTrue(SlackScopesService.requiredOptional.contains("canvases:read"))
    }

    func testRequestedReturnsUnionSorted() {
        let requested = SlackScopesService.requested()
        XCTAssertEqual(requested.count, 18)
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
