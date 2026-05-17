import Foundation

/// Phase Track-6 P2 — pure transition detector for Xcode build, scheme and
/// run-destination lifecycle. Spec §4.1.
///
/// Sibling to the existing Track-4 S2 `XcodeStateMachine`. Both consume the
/// same enriched `XcodeObservation` per AppleScript tick. The S2 machine
/// emits `xcode_active_doc_changed` + `xcode_build_state_changed`; this one
/// emits the four P2 event_kinds (build_started / build_finished /
/// scheme_changed / run_destination_changed).
///
/// First observation in a session emits NOTHING — we have no prior to diff
/// against, and over-emitting on cold start would corrupt the activity feed.
/// Tradeoff: a build already running at Agent-start moment will have its
/// `duration_ms` measured from "when we first noticed" rather than the
/// actual start; the imprecision is documented in spec §6.1 and applies only
/// to the cold-start tick.
public struct XcodeBuildLifecycleStateMachine: Sendable, Hashable {
    private var prev: XcodeObservation?
    private var buildStartedMs: Int64?

    public init() {}

    public mutating func observe(_ obs: XcodeObservation, nowMs: Int64) -> [RawEvent] {
        guard let p = prev else {
            // First observation: lock in the state, emit nothing.
            prev = obs
            if obs.buildState == .running {
                buildStartedMs = nowMs  // best-effort on cold start
            }
            return []
        }

        var events: [RawEvent] = []

        // 1. scheme_changed — fires before lifecycle events so consumers see
        //    the new scheme name on the matched build_started.
        if let event = Self.detectSchemeChanged(prev: p, obs: obs, nowMs: nowMs) {
            events.append(event)
        }

        // 2. run_destination_changed — bucketed diff only.
        if let event = Self.detectRunDestinationChanged(prev: p, obs: obs, nowMs: nowMs) {
            events.append(event)
        }

        // 3. build_started — any non-running prev → running.
        if let event = detectBuildStarted(prev: p, obs: obs, nowMs: nowMs) {
            events.append(event)
        }

        // 4. build_finished — running → terminal (succeeded/failed).
        if let event = detectBuildFinished(prev: p, obs: obs, nowMs: nowMs) {
            events.append(event)
        }

        // 5. Cancel path — running → idle without going through a terminal
        //    state. Xcode emits this when the user hits Cmd+. mid-build.
        //    `XcodeBuildState` doesn't have a `.cancelled` case (AppleScript
        //    maps it to `.idle` in S2), so we treat running→idle as cancel
        //    and clear `buildStartedMs` to keep the next build's duration
        //    correct. No `build_finished` is emitted — duration_ms would be
        //    meaningless for a canceled build, and the activity feed already
        //    has `build_state_changed` (S2) for the visible side effect.
        if p.buildState == .running, obs.buildState == .idle {
            buildStartedMs = nil
        }

        prev = obs
        return events
    }

    private static func detectSchemeChanged(
        prev p: XcodeObservation, obs: XcodeObservation, nowMs: Int64
    ) -> RawEvent? {
        guard p.schemeName != obs.schemeName else { return nil }
        var payload: [String: String] = ["event_kind": "xcode_scheme_changed"]
        if let s = obs.schemeName { payload["scheme"] = s }
        if let prevScheme = p.schemeName { payload["scheme_prev"] = prevScheme }
        if let pj = obs.projectName { payload["project"] = pj }
        return makeEvent(payload, nowMs: nowMs)
    }

    private static func detectRunDestinationChanged(
        prev p: XcodeObservation, obs: XcodeObservation, nowMs: Int64
    ) -> RawEvent? {
        guard p.runDestinationBucket != obs.runDestinationBucket else { return nil }
        let payload: [String: String] = [
            "event_kind": "xcode_run_destination_changed",
            "run_destination_bucket": obs.runDestinationBucket.rawValue,
            "run_destination_bucket_prev": p.runDestinationBucket.rawValue,
        ]
        return makeEvent(payload, nowMs: nowMs)
    }

    private mutating func detectBuildStarted(
        prev p: XcodeObservation, obs: XcodeObservation, nowMs: Int64
    ) -> RawEvent? {
        guard p.buildState != .running, obs.buildState == .running else { return nil }
        var payload: [String: String] = [
            "event_kind": "xcode_build_started",
            "run_destination_bucket": obs.runDestinationBucket.rawValue,
        ]
        if let s = obs.schemeName { payload["scheme"] = s }
        if let pj = obs.projectName { payload["project"] = pj }
        buildStartedMs = nowMs
        return Self.makeEvent(payload, nowMs: nowMs)
    }

    private mutating func detectBuildFinished(
        prev p: XcodeObservation, obs: XcodeObservation, nowMs: Int64
    ) -> RawEvent? {
        guard p.buildState == .running, obs.buildState.isTerminal else { return nil }
        var payload: [String: String] = [
            "event_kind": "xcode_build_finished",
            "status": obs.buildState.rawValue,
            "run_destination_bucket": obs.runDestinationBucket.rawValue,
        ]
        if let s = obs.schemeName { payload["scheme"] = s }
        if let pj = obs.projectName { payload["project"] = pj }
        if let started = buildStartedMs {
            payload["duration_ms"] = String(max(0, nowMs - started))
        }
        buildStartedMs = nil
        return Self.makeEvent(payload, nowMs: nowMs)
    }

    private static func makeEvent(_ payload: [String: String], nowMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: payload
        )
    }
}

extension XcodeBuildState {
    fileprivate var isTerminal: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .idle, .running: return false
        }
    }
}
