import XCTest
@testable import LeafCore

final class AttentionEmissionPlannerTests: XCTestCase {

    // MARK: - Stubs

    private final class StubContextProvider: WindowContextProvider, @unchecked Sendable {
        var stubbedTitle: String? = nil
        var stubbedURL: String? = nil
        /// Per-bundle title override (takes precedence over `stubbedTitle` for
        /// matched bundle IDs). Used by Track-6 P6 tests to stub vscode-family
        /// titles independently of Xcode/Safari fixtures.
        var titlesByBundle: [String: String] = [:]
        var titleQueriedFor: [String] = []
        var urlQueriedFor: [String] = []

        func windowTitle(forPid pid: pid_t, bundleID: String) -> String? {
            titleQueriedFor.append(bundleID)
            if let t = titlesByBundle[bundleID] { return t }
            return stubbedTitle
        }

        func browserURL(forPid pid: pid_t, bundleID: String) -> String? {
            urlQueriedFor.append(bundleID)
            return stubbedURL
        }
    }

    private final class StubTrustChecker: AXTrustChecker, @unchecked Sendable {
        var trusted: Bool = true
        func isAXTrusted() -> Bool { trusted }
    }

    private struct StubClassifier: AppCategoryClassifier {
        // Track-6 P6 — vscode-family bundles classified as .dev so policy
        // returns L3 (window title read enabled).
        let dev: Set<String> = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.visualstudio.code.oss"        // VSCodium
        ]
        let browse: Set<String> = ["com.apple.Safari"]
        func category(for bundleID: String) -> AppCategory {
            if dev.contains(bundleID) { return .dev }
            if browse.contains(bundleID) { return .browse }
            return .other
        }
    }

    private func makePlanner(
        context: StubContextProvider = StubContextProvider(),
        trust: StubTrustChecker = StubTrustChecker(),
        classifier: any AppCategoryClassifier = StubClassifier(),
        policy: AttentionGranularityPolicy? = nil
    ) -> AttentionEmissionPlanner {
        let resolvedPolicy = policy ?? DefaultAttentionGranularityPolicy(classifier: classifier)
        return AttentionEmissionPlanner(
            policy: resolvedPolicy,
            classifier: classifier,
            contextProvider: context,
            trustChecker: trust
        )
    }

    /// Track-6 P6 ergonomic overload: pin a fixed granularity for ALL bundles
    /// via a forcing policy + stub per-bundle window titles + AX trust toggle.
    /// Keeps test bodies focused on the parser-hook contract without restating
    /// the policy/classifier/trust plumbing.
    private func makePlanner(
        level: AttentionGranularityLevel,
        axTrusted: Bool,
        titles: [String: String]
    ) -> AttentionEmissionPlanner {
        let ctx = StubContextProvider()
        ctx.titlesByBundle = titles
        let trust = StubTrustChecker()
        trust.trusted = axTrusted
        let classifier = StubClassifier()
        let forcingPolicy = ForcingGranularityPolicy(level: level)
        return AttentionEmissionPlanner(
            policy: forcingPolicy,
            classifier: classifier,
            contextProvider: ctx,
            trustChecker: trust
        )
    }

    private struct ForcingGranularityPolicy: AttentionGranularityPolicy {
        let level: AttentionGranularityLevel
        func maxGranularity(for bundleID: String) -> AttentionGranularityLevel { level }
    }

    // MARK: - App-switch path

    func testAppSwitch_devBundle_axTitlePresent_payloadHasWindowTitle() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "MyApp.xcodeproj — ContentView.swift"
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(event?.signalType, .attention)
        XCTAssertEqual(event?.payload["window_title"], "MyApp.xcodeproj — ContentView.swift")
        XCTAssertNil(event?.payload["browser_url"])
    }

    func testAppSwitch_devBundle_axReturnsEmptyTitle_noWindowTitleField() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = ""
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertNil(event?.payload["window_title"])
    }

    func testAppSwitch_devBundle_axReturnsWhitespaceTitle_noWindowTitleField() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "   \n  "
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertNil(event?.payload["window_title"])
    }

    func testAppSwitch_unknownBundleL1_noWindowTitleEvenIfAXReturnsOne() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "Some title"
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "io.example.unknown", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertNil(event?.payload["window_title"])
        XCTAssertNil(event?.payload["browser_url"])
        // Provider must not be hit for L1 — we save AX calls
        XCTAssertTrue(ctx.titleQueriedFor.isEmpty)
        XCTAssertTrue(ctx.urlQueriedFor.isEmpty)
    }

    func testAppSwitch_axNotTrusted_emitsButNoTitle() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "Some title"
        let trust = StubTrustChecker()
        trust.trusted = false
        let planner = makePlanner(context: ctx, trust: trust)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event, "should still emit base attention event")
        XCTAssertEqual(event?.bundleID, "com.apple.dt.Xcode")
        XCTAssertNil(event?.payload["window_title"])
    }

    // MARK: - Browser bundles

    func testAppSwitch_browserBundle_bothTitleAndURLQueried() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "GitHub — Pull Request #42"
        ctx.stubbedURL = "https://github.com/owner/repo/pull/42"
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.Safari", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.payload["window_title"], "GitHub — Pull Request #42")
        XCTAssertEqual(event?.payload["browser_url"], "https://github.com/owner/repo/pull/42")
        XCTAssertEqual(ctx.titleQueriedFor, ["com.apple.Safari"])
        XCTAssertEqual(ctx.urlQueriedFor, ["com.apple.Safari"])
    }

    func testAppSwitch_devBundle_browserURLNotQueried() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "Xcode title"
        let planner = makePlanner(context: ctx)

        _ = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)

        XCTAssertEqual(ctx.titleQueriedFor, ["com.apple.dt.Xcode"])
        XCTAssertTrue(ctx.urlQueriedFor.isEmpty, "non-browser apps must not trigger URL extraction")
    }

    func testAppSwitch_browserBundle_urlAbsent_noBrowserURLField() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "Some Page"
        ctx.stubbedURL = nil
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.Safari", pid: 1234, reason: .appSwitch)

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.payload["window_title"], "Some Page")
        XCTAssertNil(event?.payload["browser_url"])
    }

    // MARK: - Polling-tick diff suppression

    func testWindowPoll_sameBundleSameTitle_returnsNil() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "ContentView.swift"
        let planner = makePlanner(context: ctx)

        let first = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .windowPoll)
        XCTAssertNotNil(first)

        let second = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .windowPoll)
        XCTAssertNil(second, "diff suppression must skip when (bundle, title) unchanged")
    }

    func testWindowPoll_sameBundleDifferentTitle_emits() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "ContentView.swift"
        let planner = makePlanner(context: ctx)

        let first = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .windowPoll)
        XCTAssertNotNil(first)

        ctx.stubbedTitle = "Model.swift"
        let second = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .windowPoll)
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.payload["window_title"], "Model.swift")
    }

    func testWindowPoll_differentBundle_emits() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "Title"
        let planner = makePlanner(context: ctx)

        _ = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .windowPoll)
        let second = planner.plan(bundleID: "com.apple.Safari", pid: 5678, reason: .windowPoll)
        XCTAssertNotNil(second, "bundle change must emit even when title equal")
    }

    func testAppSwitch_sameBundleSameTitle_alwaysEmits() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "ContentView.swift"
        let planner = makePlanner(context: ctx)

        let first = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)
        XCTAssertNotNil(first)

        // appSwitch — explicit user action, never suppressed
        let second = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)
        XCTAssertNotNil(second, "app-switch must always emit (no diff suppression)")
    }

    // MARK: - Sanitization

    func testTitle_overlyLong_truncatedTo200() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = String(repeating: "x", count: 500)
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)
        XCTAssertEqual(event?.payload["window_title"]?.count, 200)
    }

    func testTitle_leadingTrailingWhitespace_trimmed() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "  Hello — world  "
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)
        XCTAssertEqual(event?.payload["window_title"], "Hello — world")
    }

    func testBrowserURL_overlyLong_truncated() {
        let ctx = StubContextProvider()
        ctx.stubbedURL = "https://example.com/" + String(repeating: "a", count: 5000)
        let planner = makePlanner(context: ctx)

        let event = planner.plan(bundleID: "com.apple.Safari", pid: 1234, reason: .appSwitch)
        XCTAssertNotNil(event?.payload["browser_url"])
        XCTAssertLessThanOrEqual(event?.payload["browser_url"]?.count ?? 99999, 1024)
    }

    // MARK: - Reason payload

    func testEventTimestamp_currentByDefault() {
        let ctx = StubContextProvider()
        ctx.stubbedTitle = "T"
        let planner = makePlanner(context: ctx)

        let before = Date()
        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1234, reason: .appSwitch)
        let after = Date()

        XCTAssertNotNil(event)
        XCTAssertGreaterThanOrEqual(event!.timestamp, before)
        XCTAssertLessThanOrEqual(event!.timestamp, after)
    }

    // MARK: - Track-6 P6 — vscode-family parser hook

    func test_p6_vscodeFamily_parsedTitleEmitsVSCodeKind() {
        let planner = makePlanner(
            level: .l3, axTrusted: true,
            titles: ["com.microsoft.VSCode": "Foo.swift — leaf — Visual Studio Code"]
        )
        let event = planner.plan(
            bundleID: "com.microsoft.VSCode", pid: 1, reason: .appSwitch
        )
        XCTAssertEqual(event?.payload["event_kind"], "vscode_active_doc_changed")
        XCTAssertEqual(event?.payload["workspace_name"], "leaf")
        XCTAssertEqual(event?.payload["file_basename"], "Foo.swift")
        XCTAssertNil(event?.payload["window_title"], "Raw window_title must be removed from payload after parse-success — privacy walkback")
        XCTAssertNil(event?.payload["raw_title"], "Success path must not emit raw_title — that's fallback-only")
        XCTAssertEqual(event?.payload["ide_bundle_id"], "com.microsoft.VSCode")
    }

    func test_p6_vscodeFamily_unparsedTitleEmitsFallback() {
        let planner = makePlanner(
            level: .l3, axTrusted: true,
            titles: ["com.microsoft.VSCode": "Custom $$$ title shape unknown"]
        )
        let event = planner.plan(
            bundleID: "com.microsoft.VSCode", pid: 1, reason: .appSwitch
        )
        XCTAssertEqual(event?.payload["event_kind"], "ide_window_title_observed")
        XCTAssertNotNil(event?.payload["raw_title"])
        // Sanitizer left non-path tokens intact.
        XCTAssertTrue(event?.payload["raw_title"]?.contains("Custom") ?? false)
        XCTAssertNil(event?.payload["window_title"], "Raw window_title must be removed from payload after fallback emit — privacy walkback")
        XCTAssertEqual(event?.payload["ide_bundle_id"], "com.microsoft.VSCode")
    }

    func test_p6_nonVSCodeBundle_unchanged() {
        // Non-vscode bundles must not gain event_kind — generic attention preserved.
        let planner = makePlanner(
            level: .l3, axTrusted: true,
            titles: ["com.apple.dt.Xcode": "Foo.swift — Xcode"]
        )
        let event = planner.plan(bundleID: "com.apple.dt.Xcode", pid: 1, reason: .appSwitch)
        XCTAssertNil(event?.payload["event_kind"])
        XCTAssertEqual(event?.payload["window_title"], "Foo.swift — Xcode")
    }

    func test_p6_vscodeFamily_fallbackSanitizesPath() {
        let planner = makePlanner(
            level: .l3, axTrusted: true,
            titles: ["com.microsoft.VSCode":
                "Foo.swift in /Users/alice/secret/project running Visual Studio Code"]
        )
        let event = planner.plan(bundleID: "com.microsoft.VSCode", pid: 1, reason: .appSwitch)
        let raw = event?.payload["raw_title"] ?? ""
        XCTAssertFalse(raw.contains("alice"))
        XCTAssertFalse(raw.contains("/secret"))
        XCTAssertTrue(raw.contains("project"))  // basename retained
    }

    func test_p6_vscodeFamily_axUntrustedSuppressesParserHook() {
        let planner = makePlanner(
            level: .l3, axTrusted: false,  // not trusted → no AX read → no parser hook
            titles: ["com.microsoft.VSCode": "Foo.swift — leaf — Visual Studio Code"]
        )
        let event = planner.plan(bundleID: "com.microsoft.VSCode", pid: 1, reason: .appSwitch)
        XCTAssertNil(event?.payload["event_kind"])
        XCTAssertNil(event?.payload["window_title"])
    }
}
