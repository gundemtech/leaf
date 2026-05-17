import Foundation

/// Phase Track-4 S3 — flush-time snapshot emitted by `CGEventTapCollector`
/// minute-boundary loop. Counter-only — keycode / .characters / .modifierFlags
/// никогда не материализуются (ADR-010 Won't-list).
///
/// `droppedReason: .locked` или `.sleeping` (mutually exclusive — `.locked`
/// has priority per spec §1 "intensity_bucket_dropped" semantics) сигналит
/// что minute попал в AFK window; в этом случае `foregroundApp` обнуляется
/// (наблюдение app под locked screen — приватный leak risk даже counter-only).
public struct IntensityBucketSnapshot: Sendable, Equatable {
    public enum DroppedReason: String, Sendable, Hashable {
        case locked
        case sleeping
    }

    public let minuteBucketMs: Int64
    public let keystrokes: UInt32
    public let mouseMoves: UInt32
    public let appSwitches: UInt32
    public let foregroundApp: String?
    public let droppedReason: DroppedReason?

    public init(
        minuteBucketMs: Int64,
        keystrokes: UInt32,
        mouseMoves: UInt32,
        appSwitches: UInt32,
        foregroundApp: String?,
        droppedReason: DroppedReason?
    ) {
        self.minuteBucketMs = minuteBucketMs
        self.keystrokes = keystrokes
        self.mouseMoves = mouseMoves
        self.appSwitches = appSwitches
        self.foregroundApp = foregroundApp
        self.droppedReason = droppedReason
    }

    /// RawEvent payload representation. Active bucket → 5 keys
    /// (event_kind / keystroke_count / mouse_move_count / app_switch_count /
    /// foreground_app). Dropped bucket → 2 keys (event_kind / state).
    /// `[String: String]` matches `RawEvent.payload` type — counts are
    /// stringified at boundary. Whitelist enforced by
    /// `CGEventTapNoContentLeakageTests`.
    public func toRawEventPayload() -> [String: String] {
        if let dropped = droppedReason {
            return [
                "event_kind": "intensity_bucket_dropped",
                "state": dropped.rawValue,
            ]
        }
        return [
            "event_kind": "intensity_snapshot",
            Schema.EventPayloadKeys.keystrokeCount: String(keystrokes),
            Schema.EventPayloadKeys.mouseMoveCount: String(mouseMoves),
            Schema.EventPayloadKeys.appSwitchCount: String(appSwitches),
            Schema.EventPayloadKeys.foregroundApp: foregroundApp ?? "",
        ]
    }
}

/// Phase Track-4 S3 — stateless formatter: takes minute-bucket counter values +
/// system-state flags, produces `IntensityBucketSnapshot`. Counter state lives
/// внутри `CGEventTapCollector` actor (OSAllocatedUnfairLock-guarded); этот
/// тип просто оформляет snapshot. Минутно-граничная semantics тестируется
/// здесь в изоляции, без CGEventTap callback или DB.
public struct IntensityBucketAccumulator: Sendable {
    /// Inputs read from a single minute boundary in `CGEventTapCollector`:
    /// three event counters (keystroke / mouseMove / appSwitch), the
    /// foreground-app bundle id at flush time, and the lock/sleep flags that
    /// gate emission (`locked` / `sleeping` → counters dropped per ADR-010).
    /// Promoted from a 6-arg flat list to a value-type bundle so the public
    /// formatter call signature stays digestible.
    public struct MinuteBucket: Sendable {
        public let bucketMs: Int64
        public let keystrokes: UInt32
        public let mouseMoves: UInt32
        public let appSwitches: UInt32
        public let foregroundApp: String?
        public let wasLocked: Bool
        public let wasSleeping: Bool

        public init(
            bucketMs: Int64,
            keystrokes: UInt32,
            mouseMoves: UInt32,
            appSwitches: UInt32,
            foregroundApp: String?,
            wasLocked: Bool,
            wasSleeping: Bool
        ) {
            self.bucketMs = bucketMs
            self.keystrokes = keystrokes
            self.mouseMoves = mouseMoves
            self.appSwitches = appSwitches
            self.foregroundApp = foregroundApp
            self.wasLocked = wasLocked
            self.wasSleeping = wasSleeping
        }
    }

    public init() {}

    public func flushTo(_ bucket: MinuteBucket) -> IntensityBucketSnapshot {
        let dropped: IntensityBucketSnapshot.DroppedReason? =
            bucket.wasLocked ? .locked : (bucket.wasSleeping ? .sleeping : nil)
        return IntensityBucketSnapshot(
            minuteBucketMs: bucket.bucketMs,
            keystrokes: bucket.keystrokes,
            mouseMoves: bucket.mouseMoves,
            appSwitches: bucket.appSwitches,
            foregroundApp: dropped == nil ? bucket.foregroundApp : nil,
            droppedReason: dropped
        )
    }
}
