import XCTest
@testable import LeafCore

/// Phase 4.6.B + 4.6.C.2 + Track 7 P2 — Linear status transitions,
/// `longestUninterruptedWindow`, и 5 новых Track-7 surface breakdown полей
/// (Xcode / IDEs / Browsers / Zoom / Google Calendar). Split from
/// InsightsSnapshotTests for type_body_length.
final class InsightsSnapshotTransitionsAndTrack7Tests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptySnapshot() -> InsightsSnapshot {
        InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
    }

    // MARK: - Phase 4.6.C.2 — longestUninterruptedWindow

    func testSnapshotLongestUninterruptedWindowDefaultNil() {
        XCTAssertNil(emptySnapshot().longestUninterruptedWindow,
            "convenience init без аргумента → default nil (backwards compat)")
    }

    func testSnapshotLongestUninterruptedWindowExplicit() {
        let win = UninterruptedWindow(
            start: now,
            end: now.addingTimeInterval(9000),
            durationSeconds: 9000,
            sourcesActiveInPeriod: ["github", "slack"]
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            longestUninterruptedWindow: win
        )
        XCTAssertEqual(snapshot.longestUninterruptedWindow?.durationSeconds, 9000)
        XCTAssertEqual(snapshot.longestUninterruptedWindow?.sourcesActiveInPeriod,
                       ["github", "slack"])
    }

    /// Default extension impl возвращает nil — StubInsights не override'ит,
    /// поэтому iOS-future / CI и тесты с stub'ом работают без ошибок.
    func testStubInsightsLongestUninterruptedWindowDefaultsToNil() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-insights-window-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
        let stub = StubInsights(database: db)
        let win = try stub.longestUninterruptedWindow(
            period: DateInterval(start: now, end: now.addingTimeInterval(3600))
        )
        XCTAssertNil(win, "default extension impl — nil")
    }

    // MARK: - Phase 4.6.B — Linear status transitions

    func testLinearBreakdownTransitionsDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.transitions, "default nil — backwards compat для existing init callsite'ов")
        XCTAssertNil(bd.completionRate, "default nil — same convention")
    }

    func testLinearBreakdownTransitionsExplicit() {
        let transitions = LinearTransitionBreakdown(started: 2, completed: 3, canceled: 1, reopened: 1)
        let bd = LinearActivityBreakdown(
            issuesTouched: 5,
            byProject: [],
            byStatus: [],
            transitions: transitions,
            completionRate: 0.5
        )
        XCTAssertEqual(bd.transitions?.started, 2)
        XCTAssertEqual(bd.transitions?.completed, 3)
        XCTAssertEqual(bd.transitions?.canceled, 1)
        XCTAssertEqual(bd.transitions?.reopened, 1)
        XCTAssertEqual(bd.transitions?.total, 7, "sum может exceed unique transition count для completed→canceled overlap")
        XCTAssertEqual(bd.completionRate, 0.5)
    }

    func testLinearTransitionBreakdownCodableRoundTrip() throws {
        let original = LinearTransitionBreakdown(started: 5, completed: 3, canceled: 1, reopened: 2)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LinearTransitionBreakdown.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.total, 11)
    }

    func testLinearTransitionBreakdownEmpty() {
        let empty = LinearTransitionBreakdown.empty
        XCTAssertEqual(empty.started, 0)
        XCTAssertEqual(empty.completed, 0)
        XCTAssertEqual(empty.canceled, 0)
        XCTAssertEqual(empty.reopened, 0)
        XCTAssertEqual(empty.total, 0)
    }

    func testSnapshotLinearTransitionsRoundTrip() {
        let transitions = LinearTransitionBreakdown(started: 1, completed: 2, canceled: 0, reopened: 0)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearTransitions: transitions,
            linearCompletionRate: 2.0 / 3.0
        )
        XCTAssertEqual(snapshot.linearTransitions?.started, 1)
        XCTAssertEqual(snapshot.linearTransitions?.completed, 2)
        XCTAssertEqual(snapshot.linearTransitions?.total, 3)
        XCTAssertEqual(snapshot.linearCompletionRate, 2.0 / 3.0)
    }

    func testSnapshotLinearTransitionsDefaultsBackwardCompat() {
        // Existing callsite'ы без новых параметров продолжают работать.
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3
        )
        XCTAssertNil(snapshot.linearTransitions, "default nil")
        XCTAssertNil(snapshot.linearCompletionRate, "default nil")
    }

    func testStubInsightsLinearTransitionsAndCompletionRateDefaults() throws {
        // StubInsights наследует default extension impl → .empty / nil
        // (для CI / iOS-future / тест-сценариев без LeafCorePrivate).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-stub-tx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try Database.openForWrite(at: tmp, config: .weakDefaults)
        let reader = try Database.openForRead(at: tmp, config: .weakDefaults)
        let stub = StubInsights(database: reader)
        let now = Date()
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let transitions = try stub.linearTransitions(period: period)
        XCTAssertEqual(transitions, .empty, "default extension → .empty")
        let rate = try stub.linearCompletionRate(period: period)
        XCTAssertNil(rate, "default extension → nil")
    }

    // MARK: - Track 7 P2-collapsed — 5 new surface breakdown defaults on StubInsights

    private func makeStubInsights(label: String) throws -> StubInsights {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-stub-\(label)-\(UUID().uuidString).sqlite")
        _ = try Database.openForWrite(at: tmp, config: .weakDefaults)
        let reader = try Database.openForRead(at: tmp, config: .weakDefaults)
        return StubInsights(database: reader)
    }

    func testStubInsightsXcodeActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "xcode")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.xcodeActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsIDEsActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "ides")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.idesActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsBrowsersActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "browsers")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.browsersActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsZoomActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "zoom")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.zoomActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsGoogleCalendarActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "gcal")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.googleCalendarActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    // MARK: - Track 7 P2-collapsed — 5 new InsightsSnapshot optional surface fields

    /// Convenience init без новых параметров → все 5 surface полей nil.
    /// Существующие callsite'ы (DerivedInsightsFactory / ProdInsightsSnapshotBuilder /
    /// MCP handlers / view-models) не трогают новые поля — back-compat guaranteed
    /// nil defaults.
    func test_track7P2Defaults_areNil() {
        let snapshot = emptySnapshot()
        XCTAssertNil(snapshot.xcodeActivity)
        XCTAssertNil(snapshot.idesActivity)
        XCTAssertNil(snapshot.browsersActivity)
        XCTAssertNil(snapshot.zoomActivity)
        XCTAssertNil(snapshot.googleCalendarActivity)
    }

    /// Full memberwise init принимает все 5 опциональных surface полей —
    /// passing `.empty` round-trips through the stored properties.
    func test_track7P2_explicitValuesRoundTrip() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            xcodeActivity: .empty,
            idesActivity: .empty,
            browsersActivity: .empty,
            zoomActivity: .empty,
            googleCalendarActivity: .empty
        )
        XCTAssertEqual(snapshot.xcodeActivity, .empty)
        XCTAssertEqual(snapshot.idesActivity, .empty)
        XCTAssertEqual(snapshot.browsersActivity, .empty)
        XCTAssertEqual(snapshot.zoomActivity, .empty)
        XCTAssertEqual(snapshot.googleCalendarActivity, .empty)
        XCTAssertTrue(snapshot.isEmpty,
            ".empty surface breakdowns don't flip isEmpty — Track 7 P2 fields excluded from isEmpty check (nil = not computed, not zero data)")
    }
}
