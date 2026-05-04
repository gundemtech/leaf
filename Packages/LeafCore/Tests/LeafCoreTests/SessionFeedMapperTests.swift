import XCTest
@testable import LeafCore

/// Phase 4.10.B — SessionFeedMapper aggregation contract.
///
/// Mapper — pure stateless. Тесты проверяют:
///  1. Boundary cases (empty / single / nil bundle / unknown signal_type).
///  2. Run-aggregation: same (bundle, contextKey) within gap → одна сессия.
///  3. Boundaries: смена bundle / смена title / idle context / gap > threshold.
///  4. End-point semantics при разных способах закрытия сессии.
///  5. minDurationSec фильтр.
///  6. Категория проставляется через `AppCategoryClassifier`.
final class SessionFeedMapperTests: XCTestCase {

    // MARK: - Helpers

    private let baseTs = Date(timeIntervalSince1970: 1_700_000_000)
    private let xcode = "com.apple.dt.Xcode"
    private let safari = "com.apple.Safari"
    private let unknown = "io.example.unknown"
    private let classifier = StubClassifier(devBundles: ["com.apple.dt.Xcode"], browseBundles: ["com.apple.Safari"])

    private func attention(
        id: Int64,
        offset seconds: TimeInterval,
        bundle: String?,
        title: String? = nil,
        url: String? = nil
    ) -> SessionMapperRow {
        var payload: [String: String] = [:]
        if let title { payload["window_title"] = title }
        if let url { payload["browser_url"] = url }
        return SessionMapperRow(
            id: id,
            timestamp: baseTs.addingTimeInterval(seconds),
            signalType: "attention",
            bundleID: bundle,
            payload: payload
        )
    }

    private func context(
        id: Int64,
        offset seconds: TimeInterval,
        state: String
    ) -> SessionMapperRow {
        SessionMapperRow(
            id: id,
            timestamp: baseTs.addingTimeInterval(seconds),
            signalType: "context",
            bundleID: nil,
            payload: ["state": state]
        )
    }

    // MARK: - Boundary

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(
            SessionFeedMapper.map(rows: []),
            []
        )
    }

    func testSingleAttentionExtendsToReferenceEnd() {
        let rows = [attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift")]
        let refEnd = baseTs.addingTimeInterval(30)
        let sessions = SessionFeedMapper.map(
            rows: rows,
            classifier: classifier,
            gapThresholdSec: 90,
            minDurationSec: 5,
            referenceEnd: refEnd
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].bundleID, xcode)
        XCTAssertEqual(sessions[0].contextLabel, "Foo.swift")
        XCTAssertEqual(sessions[0].duration, 30, accuracy: 0.001)
        XCTAssertEqual(sessions[0].eventCount, 1)
        XCTAssertEqual(sessions[0].category, .dev)
    }

    func testSingleAttentionTrailingCappedByGapThreshold() {
        // refEnd well past gap threshold → end clamped to lastTs + gap.
        let rows = [attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift")]
        let refEnd = baseTs.addingTimeInterval(10_000)
        let sessions = SessionFeedMapper.map(
            rows: rows,
            gapThresholdSec: 90,
            minDurationSec: 5,
            referenceEnd: refEnd
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration, 90, accuracy: 0.001)
    }

    func testNilBundleIDIgnored() {
        let rows = [
            attention(id: 1, offset: 0, bundle: nil, title: "Foo"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Bar.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].bundleID, xcode)
    }

    func testEmptyBundleIDIgnored() {
        let rows = [
            attention(id: 1, offset: 0, bundle: "", title: "Foo"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Bar.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.count, 1)
    }

    func testUnknownSignalTypesIgnored() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            SessionMapperRow(
                id: 2, timestamp: baseTs.addingTimeInterval(15),
                signalType: "aiCollaboration",
                bundleID: nil, payload: [:]
            ),
            attention(id: 3, offset: 30, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].eventCount, 2)
    }

    // MARK: - Run aggregation

    func testThreeAttentionEventsSameKeyWithinGap_OneSession() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo.swift"),
            attention(id: 3, offset: 60, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            gapThresholdSec: 90,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, 1)
        XCTAssertEqual(sessions[0].eventCount, 3)
        XCTAssertEqual(sessions[0].start, baseTs)
        // trailing extension capped by gap threshold (60 + 90 = 150, but refEnd=120).
        XCTAssertEqual(sessions[0].end, baseTs.addingTimeInterval(120))
    }

    func testWindowTitleEmptyPayloadFallsBackToBundle() {
        // Single open session for a bundle with no window_title — still aggregates.
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: nil),
            attention(id: 2, offset: 30, bundle: xcode, title: nil)
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions[0].contextLabel)
        XCTAssertEqual(sessions[0].eventCount, 2)
    }

    func testBrowserURLUsedAsContextKey() {
        let rows = [
            attention(id: 1, offset: 0, bundle: safari, url: "https://example.com/a"),
            attention(id: 2, offset: 30, bundle: safari, url: "https://example.com/a"),
            attention(id: 3, offset: 60, bundle: safari, url: "https://example.com/b")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].contextLabel, "https://example.com/a")
        XCTAssertEqual(sessions[0].eventCount, 2)
        XCTAssertEqual(sessions[1].contextLabel, "https://example.com/b")
    }

    // MARK: - Boundaries

    func testTwoBundlesProduceTwoSessions() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo.swift"),
            attention(id: 3, offset: 60, bundle: safari, url: "https://x")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].bundleID, xcode)
        XCTAssertEqual(sessions[0].end, baseTs.addingTimeInterval(60), "ends at boundary event ts")
        XCTAssertEqual(sessions[1].bundleID, safari)
        XCTAssertEqual(sessions[1].start, baseTs.addingTimeInterval(60))
    }

    func testSameBundleDifferentTitleProducesTwoSessions() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 60, bundle: xcode, title: "Bar.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(90)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].contextLabel, "Foo.swift")
        XCTAssertEqual(sessions[1].contextLabel, "Bar.swift")
    }

    func testIdleContextSplitsSessionEvenForSameKey() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo.swift"),
            context(id: 3, offset: 45, state: "idle"),
            attention(id: 4, offset: 60, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].end, baseTs.addingTimeInterval(45), "ends at idle ts")
        XCTAssertEqual(sessions[0].eventCount, 2)
        XCTAssertEqual(sessions[1].start, baseTs.addingTimeInterval(60))
        XCTAssertEqual(sessions[1].eventCount, 1)
    }

    func testActiveContextDoesNotSplitSession() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            context(id: 2, offset: 30, state: "active"),
            attention(id: 3, offset: 60, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].eventCount, 2)
    }

    func testGapExceedingThresholdSplitsAndCapsEnd() {
        // gap = 200s > threshold(90) → first session ends at lastTs + threshold.
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 200, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            gapThresholdSec: 90,
            referenceEnd: baseTs.addingTimeInterval(300)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].end, baseTs.addingTimeInterval(90), "capped at lastTs + gapThreshold")
        XCTAssertEqual(sessions[1].start, baseTs.addingTimeInterval(200))
    }

    // MARK: - minDuration filter

    func testSessionShorterThanMinDurationDropped() {
        // Two short sessions back-to-back; minDuration=10 drops both.
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 3, bundle: safari, url: "https://x"),
            attention(id: 3, offset: 6, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            minDurationSec: 10,
            referenceEnd: baseTs.addingTimeInterval(8)
        )
        // First two close at ts of next event (3s, 3s) — dropped.
        // Third trailing extends to refEnd (offset 8) → duration 2s — dropped.
        XCTAssertTrue(sessions.isEmpty)
    }

    func testRapidTransitionsKeepLongerOuterSession() {
        // Long Xcode session, brief Slack flicker, back to Xcode (different filename).
        // minDuration=10 drops the brief flicker.
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo.swift"),
            attention(id: 3, offset: 60, bundle: "com.tinyspeck.slackmacgap", title: "general"),
            attention(id: 4, offset: 62, bundle: xcode, title: "Bar.swift"),
            attention(id: 5, offset: 90, bundle: xcode, title: "Bar.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            gapThresholdSec: 90,
            minDurationSec: 10,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].bundleID, xcode)
        XCTAssertEqual(sessions[0].contextLabel, "Foo.swift")
        XCTAssertEqual(sessions[1].bundleID, xcode)
        XCTAssertEqual(sessions[1].contextLabel, "Bar.swift")
    }

    // MARK: - Sorting

    func testUnsortedRowsAreNormalized() {
        let rows = [
            attention(id: 3, offset: 60, bundle: xcode, title: "Foo.swift"),
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo.swift"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo.swift")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(120)
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, 1, "session id = first event by ts, not by input order")
        XCTAssertEqual(sessions[0].eventCount, 3)
    }

    // MARK: - Category mapping

    func testCategoryFromClassifier_unknownBundleIsOther() {
        let rows = [
            attention(id: 1, offset: 0, bundle: unknown, title: "Foo"),
            attention(id: 2, offset: 30, bundle: unknown, title: "Foo")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            classifier: classifier,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.first?.category, .other)
    }

    func testCategoryFromClassifier_knownDevBundle() {
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            classifier: classifier,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.first?.category, .dev)
    }

    func testCategoryFromClassifier_emptyClassifierFallsBackToOther() {
        // No classifier override → default Empty → everything .other.
        let rows = [
            attention(id: 1, offset: 0, bundle: xcode, title: "Foo"),
            attention(id: 2, offset: 30, bundle: xcode, title: "Foo")
        ]
        let sessions = SessionFeedMapper.map(
            rows: rows,
            referenceEnd: baseTs.addingTimeInterval(60)
        )
        XCTAssertEqual(sessions.first?.category, .other)
    }
}

private struct StubClassifier: AppCategoryClassifier {
    var devBundles: Set<String> = []
    var browseBundles: Set<String> = []

    func category(for bundleID: String) -> AppCategory {
        if devBundles.contains(bundleID) { return .dev }
        if browseBundles.contains(bundleID) { return .browse }
        return .other
    }
}
