import Foundation

/// Phase Track-6 P2 — pure transition detector for test-run lifecycle.
/// Spec §4.2. FSEvents-driven: external callers feed in `observeStarted`
/// (on xcresult dir created) and `observeFinished` (after Info.plist stable
/// write + xcresulttool parse).
///
/// The machine carries a per-bundle de-duplication set (LRU, cap 256). Both
/// `observeStarted` and `observeFinished` are idempotent per `bundlePath` —
/// a second call for the same path returns an empty array.
public struct XcodeTestRunStateMachine: Sendable, Hashable {
    private var seenStarted: [String] = []
    private var seenFinished: [String] = []
    private static let lruCap = 256

    public init() {}

    public mutating func observeStarted(
        bundlePath: String,
        scheme: String?,
        runDestinationBucket: RunDestinationBucket,
        nowMs: Int64
    ) -> [RawEvent] {
        if seenStarted.contains(bundlePath) { return [] }
        seenStarted.append(bundlePath)
        if seenStarted.count > Self.lruCap {
            seenStarted.removeFirst(seenStarted.count - Self.lruCap)
        }
        var payload: [String: String] = [
            "event_kind": "xcode_test_run_started",
            "run_destination_bucket": runDestinationBucket.rawValue,
        ]
        if let s = scheme { payload["scheme"] = s }
        return [Self.event(payload, nowMs: nowMs)]
    }

    public mutating func observeFinished(
        bundlePath: String,
        summary: XcresultTestSummary,
        nowMs: Int64
    ) -> [RawEvent] {
        if seenFinished.contains(bundlePath) { return [] }
        seenFinished.append(bundlePath)
        if seenFinished.count > Self.lruCap {
            seenFinished.removeFirst(seenFinished.count - Self.lruCap)
        }
        var payload: [String: String] = [
            "event_kind": "xcode_test_run_finished",
            "passed_count": String(summary.passedCount),
            "failed_count": String(summary.failedCount),
            "skipped_count": String(summary.skippedCount),
            "expected_failure_count": String(summary.expectedFailureCount),
            "total_count": String(summary.totalCount),
            "status": summary.failedCount > 0 ? "failed" : "succeeded",
            "run_destination_bucket": summary.destinationBucket.rawValue,
        ]
        if let s = summary.scheme { payload["scheme"] = s }
        if let d = summary.durationMs { payload["duration_ms"] = String(d) }
        return [Self.event(payload, nowMs: nowMs)]
    }

    private static func event(_ payload: [String: String], nowMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: payload
        )
    }
}
