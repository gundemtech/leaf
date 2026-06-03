import Foundation

/// Phase Track-4 S2 — pure dispatch logic for `AppleScriptCollector`.
/// Extracted into LeafCore so it can be SPM-tested (LeafAgent has no
/// test target). The real collector wires this logic to `AppKit` via
/// the `isInstalled` closure and to its `EventWriter` via the returned
/// `[RawEvent]`.
///
/// Per-tick contract:
///   1. Skip if `localAppsStore.isEnabled(bundleID)` is false.
///   2. Skip if `permissionStore.shouldProbe(bundleID, nowMs)` is false
///      (denied < 24h ago, appNotInstalled terminal, unavailable terminal).
///   3. Skip + record `.appNotInstalled` if `isInstalled(bundleID)` is false.
///   4. Execute adapter's `tickScript` via bridge.
///   5. Switch on result:
///      - `.success(d)` → record `.granted` + parse + observe → events.
///      - `.denied` → record `.denied(nowMs)`.
///      - `.appNotRunning` → silent no-op.
///      - `.timeout` → log no-op (caller's responsibility).
///      - `.scriptError(c, m)` → log no-op.
///      - `.unavailable` → record `.unavailable`.
public enum AppleScriptDispatchLogic {
    public enum DiagnosticEvent: Sendable, Equatable {
        case timeout(bundleID: String)
        case scriptError(bundleID: String, code: Int, message: String)
    }

    public struct TickOutcome: Sendable {
        public let events: [RawEvent]
        public let diagnostics: [DiagnosticEvent]
        public init(events: [RawEvent], diagnostics: [DiagnosticEvent]) {
            self.events = events
            self.diagnostics = diagnostics
        }
    }

    /// Dispatch one tick for one adapter. `adapter` is `inout` because the
    /// protocol's `observe` is mutating (state-machine inside).
    @MainActor
    public static func tickAdapter(
        _ adapter: inout any AppleScriptAdapter,
        bridge: AppleScriptBridge,
        permissionStore: AppleScriptPermissionStore,
        localAppsStore: LocalAppsStore,
        isInstalled: @Sendable (String) -> Bool,
        isRunning: @Sendable (String) -> Bool = { _ in true },
        nowMs: Int64
    ) async -> TickOutcome {
        var allEvents: [RawEvent] = []
        var diagnostics: [DiagnosticEvent] = []

        for bundleID in adapter.targetBundleIDs.sorted() {
            guard localAppsStore.isEnabled(bundleID) else { continue }
            guard permissionStore.shouldProbe(for: bundleID, nowMs: nowMs) else { continue }
            guard isInstalled(bundleID) else {
                permissionStore.record(.appNotInstalled, for: bundleID, nowMs: nowMs)
                continue
            }
            // Settings dead-toggle remediation (WS4): skip apps that are installed
            // but not running. Sending an AppleEvent to a closed app auto-launches
            // it every tick (a real UX bug) and produces the per-tick error spam.
            // Silent skip — no dispatch, no diagnostic (mirrors `.appNotRunning`).
            guard isRunning(bundleID) else { continue }
            let script = adapter.tickScript(for: bundleID)
            let result = await bridge.executeScript(script, timeoutSec: adapter.timeoutSec)
            switch result {
            case .success(let data):
                permissionStore.record(.granted, for: bundleID, nowMs: nowMs)
                guard let obs = adapter.parse(data, for: bundleID) else { continue }
                let events = adapter.observe(obs, nowMs: nowMs, localAppsStore: localAppsStore)
                allEvents.append(contentsOf: events)
            case .denied:
                permissionStore.record(.denied(nowMs), for: bundleID, nowMs: nowMs)
            case .appNotRunning:
                continue
            case .timeout:
                diagnostics.append(.timeout(bundleID: bundleID))
            case .scriptError(let code, let message):
                diagnostics.append(.scriptError(bundleID: bundleID, code: code, message: message))
            case .unavailable:
                permissionStore.record(.unavailable, for: bundleID, nowMs: nowMs)
            }
        }
        return TickOutcome(events: allEvents, diagnostics: diagnostics)
    }
}
