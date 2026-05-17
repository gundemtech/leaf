import XCTest

@testable import LeafCore

final class IntensityBucketAccumulatorTests: XCTestCase {

    func testActiveBucketProducesSnapshot() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 1_000,
                keystrokes: 50,
                mouseMoves: 100,
                appSwitches: 3,
                foregroundApp: "com.apple.dt.Xcode",
                wasLocked: false,
                wasSleeping: false
            )

        )
        XCTAssertEqual(snap.minuteBucketMs, 1_000)
        XCTAssertEqual(snap.keystrokes, 50)
        XCTAssertEqual(snap.mouseMoves, 100)
        XCTAssertEqual(snap.appSwitches, 3)
        XCTAssertEqual(snap.foregroundApp, "com.apple.dt.Xcode")
        XCTAssertNil(snap.droppedReason)
    }

    func testForegroundAppPreservedWhenActive() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 60_000,
                keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                foregroundApp: "com.spotify.client",
                wasLocked: false, wasSleeping: false
            )

        )
        XCTAssertEqual(snap.foregroundApp, "com.spotify.client")
    }

    func testZeroBucketStillSnapshots() {
        // All-zero bucket valid; UPSERT idempotent on PK даёт row для retention.
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 60_000,
                keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                foregroundApp: nil,
                wasLocked: false, wasSleeping: false
            )

        )
        XCTAssertNil(snap.droppedReason)
        XCTAssertNil(snap.foregroundApp)
    }

    func testLockedBucketDropsForegroundApp() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 60_000,
                keystrokes: 5, mouseMoves: 10, appSwitches: 1,
                foregroundApp: "com.apple.Safari",
                wasLocked: true, wasSleeping: false
            )

        )
        XCTAssertNil(snap.foregroundApp, "locked bucket strips foreground_app")
        XCTAssertEqual(snap.droppedReason, .locked)
    }

    func testSleepingBucketDropsForegroundApp() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 60_000,
                keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                foregroundApp: "com.apple.dt.Xcode",
                wasLocked: false, wasSleeping: true
            )

        )
        XCTAssertNil(snap.foregroundApp)
        XCTAssertEqual(snap.droppedReason, .sleeping)
    }

    func testLockedAndSleepingPrefersLocked() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 60_000,
                keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                foregroundApp: nil,
                wasLocked: true, wasSleeping: true
            )

        )
        XCTAssertEqual(snap.droppedReason, .locked, "locked takes priority")
    }

    func testBucketMsPreserved() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 1_777_777_777_777,
                keystrokes: 1, mouseMoves: 1, appSwitches: 1,
                foregroundApp: "x",
                wasLocked: false, wasSleeping: false
            )

        )
        XCTAssertEqual(snap.minuteBucketMs, 1_777_777_777_777)
    }

    func testCountersTypedUInt32Max() {
        let accumulator = IntensityBucketAccumulator()
        let snap = accumulator.flushTo(
            IntensityBucketAccumulator.MinuteBucket(
                bucketMs: 0,
                keystrokes: UInt32.max, mouseMoves: UInt32.max, appSwitches: UInt32.max,
                foregroundApp: nil,
                wasLocked: false, wasSleeping: false
            )

        )
        XCTAssertEqual(snap.keystrokes, UInt32.max)
        XCTAssertEqual(snap.mouseMoves, UInt32.max)
        XCTAssertEqual(snap.appSwitches, UInt32.max)
    }

    func testEqualityValueSemantics() {
        let a = IntensityBucketSnapshot(
            minuteBucketMs: 100, keystrokes: 1, mouseMoves: 2, appSwitches: 3,
            foregroundApp: "x", droppedReason: nil
        )
        let b = IntensityBucketSnapshot(
            minuteBucketMs: 100, keystrokes: 1, mouseMoves: 2, appSwitches: 3,
            foregroundApp: "x", droppedReason: nil
        )
        XCTAssertEqual(a, b)
    }

    func testActiveEmissionPayloadShape() {
        let snap = IntensityBucketSnapshot(
            minuteBucketMs: 60_000, keystrokes: 5, mouseMoves: 10, appSwitches: 1,
            foregroundApp: "com.apple.dt.Xcode", droppedReason: nil
        )
        let payload = snap.toRawEventPayload()
        // Whitelist enforcement: 5 keys exactly. Counts stringified
        // matching RawEvent.payload [String: String] type.
        XCTAssertEqual(payload["event_kind"], "intensity_snapshot")
        XCTAssertEqual(payload[Schema.EventPayloadKeys.keystrokeCount], "5")
        XCTAssertEqual(payload[Schema.EventPayloadKeys.mouseMoveCount], "10")
        XCTAssertEqual(payload[Schema.EventPayloadKeys.appSwitchCount], "1")
        XCTAssertEqual(payload[Schema.EventPayloadKeys.foregroundApp], "com.apple.dt.Xcode")
        XCTAssertEqual(payload.count, 5, "active payload must be exactly 5 keys (won't-list fence)")
    }

    func testDroppedEmissionPayloadShape() {
        let snap = IntensityBucketSnapshot(
            minuteBucketMs: 60_000, keystrokes: 0, mouseMoves: 0, appSwitches: 0,
            foregroundApp: nil, droppedReason: .locked
        )
        let payload = snap.toRawEventPayload()
        XCTAssertEqual(payload["event_kind"], "intensity_bucket_dropped")
        XCTAssertEqual(payload["state"], "locked")
        XCTAssertEqual(payload.count, 2, "dropped payload must be exactly 2 keys")
    }
}
