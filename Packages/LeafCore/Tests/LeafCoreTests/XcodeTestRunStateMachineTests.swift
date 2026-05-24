// Phase Track-6 P2 — XcodeTestRunStateMachine coverage.
import Testing
@testable import LeafCore

@Suite("XcodeTestRunStateMachine")
struct XcodeTestRunStateMachineTests {

    @Test func observeStarted_emitsTestRunStarted() {
        var m = XcodeTestRunStateMachine()
        let e = m.observeStarted(
            bundlePath: "/a/b/1.xcresult",
            scheme: "Leaf",
            runDestinationBucket: .macos,
            nowMs: 100
        )
        #expect(e.count == 1)
        let p = e[0].payload
        #expect(p["event_kind"] == "xcode_test_run_started")
        #expect(p["scheme"] == "Leaf")
        #expect(p["run_destination_bucket"] == "macos")
    }

    @Test func observeStartedTwice_deduped() {
        var m = XcodeTestRunStateMachine()
        _ = m.observeStarted(
            bundlePath: "/a/b/1.xcresult",
            scheme: nil,
            runDestinationBucket: .unknown,
            nowMs: 100
        )
        let e = m.observeStarted(
            bundlePath: "/a/b/1.xcresult",
            scheme: nil,
            runDestinationBucket: .unknown,
            nowMs: 200
        )
        #expect(e.isEmpty)
    }

    @Test func observeFinished_emitsTestRunFinished_withCounts() {
        var m = XcodeTestRunStateMachine()
        let summary = XcresultTestSummary(
            passedCount: 1500, failedCount: 0, skippedCount: 5,
            expectedFailureCount: 1, totalCount: 1506, durationMs: 30_000,
            scheme: "Leaf", destinationBucket: .macos
        )
        let e = m.observeFinished(bundlePath: "/a/b/1.xcresult",
                                  summary: summary, nowMs: 300)
        #expect(e.count == 1)
        let p = e[0].payload
        #expect(p["event_kind"] == "xcode_test_run_finished")
        #expect(p["passed_count"] == "1500")
        #expect(p["failed_count"] == "0")
        #expect(p["skipped_count"] == "5")
        #expect(p["expected_failure_count"] == "1")
        #expect(p["total_count"] == "1506")
        #expect(p["status"] == "succeeded")
        #expect(p["duration_ms"] == "30000")
        #expect(p["scheme"] == "Leaf")
        #expect(p["run_destination_bucket"] == "macos")
    }

    @Test func observeFinished_withFailures_statusFailed() {
        var m = XcodeTestRunStateMachine()
        let summary = XcresultTestSummary(
            passedCount: 100, failedCount: 2, skippedCount: 0,
            expectedFailureCount: 0, totalCount: 102, durationMs: 5_000,
            scheme: nil, destinationBucket: .iosSimulator
        )
        let e = m.observeFinished(bundlePath: "/x.xcresult",
                                  summary: summary, nowMs: 100)
        #expect(e[0].payload["status"] == "failed")
        #expect(e[0].payload["scheme"] == nil)
    }

    @Test func observeFinishedTwice_deduped() {
        var m = XcodeTestRunStateMachine()
        let s = XcresultTestSummary(
            passedCount: 1, failedCount: 0, skippedCount: 0,
            expectedFailureCount: 0, totalCount: 1, durationMs: nil, scheme: nil,
            destinationBucket: .macos
        )
        _ = m.observeFinished(bundlePath: "/x.xcresult", summary: s, nowMs: 100)
        let e = m.observeFinished(bundlePath: "/x.xcresult", summary: s, nowMs: 200)
        #expect(e.isEmpty)
    }

    @Test func observeFinishedWithoutStarted_stillEmits() {
        // Cold-start case: bundle appeared while watcher was offline; the
        // started event was missed but finished is still authoritative.
        var m = XcodeTestRunStateMachine()
        let s = XcresultTestSummary(
            passedCount: 1, failedCount: 0, skippedCount: 0,
            expectedFailureCount: 0, totalCount: 1, durationMs: 100, scheme: nil,
            destinationBucket: .macos
        )
        let e = m.observeFinished(bundlePath: "/x.xcresult", summary: s, nowMs: 100)
        #expect(e.count == 1)
    }

    @Test func lruEvictsAfter256Bundles() {
        var m = XcodeTestRunStateMachine()
        for i in 0..<300 {
            _ = m.observeStarted(
                bundlePath: "/b/\(i).xcresult",
                scheme: nil,
                runDestinationBucket: .unknown,
                nowMs: Int64(i)
            )
        }
        // Bundle 0 was evicted, so re-emitting should NOT be deduped.
        let e = m.observeStarted(
            bundlePath: "/b/0.xcresult",
            scheme: nil,
            runDestinationBucket: .unknown,
            nowMs: 1000
        )
        #expect(!e.isEmpty)
    }
}
