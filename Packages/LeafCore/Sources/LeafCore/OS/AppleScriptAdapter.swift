import Foundation

/// Phase Track-4 S2 — narrow marker for per-app boundary value types passed
/// across the AppleScript adapter pipeline. Concrete conformers
/// (`XcodeObservation`, `MusicTrackObservation`, ...) live in `LeafCore/OS/`
/// next to their state machine; production parsers live in
/// `LeafCorePrivate/Prod/Collectors/Apple/Prod<App>Adapter.swift` (moat).
///
/// Marker is `Sendable` only — concrete conformers add `Hashable` themselves
/// so the protocol stays existential-friendly without Self-requirement noise.
public protocol AdapterObservation: Sendable {}

/// One adapter per app (or family of apps). Conforming production types live
/// in LeafCorePrivate; the public substrate ships only the protocol +
/// `EmptyAppleScriptAdapterRegistry`.
public protocol AppleScriptAdapter: Sendable {
    /// One or more target bundle IDs this adapter handles. The JetBrains
    /// family adapter returns 11 IDE bundle IDs; most adapters return a
    /// single-element set.
    var targetBundleIDs: Set<String> { get }

    /// `ShareEventTypeKey` cases this adapter may emit. Used for registry
    /// verification + diagnostics surface.
    var eventKinds: Set<ShareEventTypeKey> { get }

    /// Poll interval per tick (per-adapter, in seconds).
    var pollIntervalSec: TimeInterval { get }

    /// Timeout per AppleScript invocation (per-adapter, in seconds). Default
    /// 1.0 for most adapters; Zoom overrides 3.0 because its `is meeting`
    /// query can block under load.
    var timeoutSec: Double { get }

    /// Script body for one tick — actual data read. The first tick after a
    /// Local Apps toggle flips ON also triggers the TCC dialog (no separate
    /// probe script).
    func tickScript(for bundleID: String) -> String

    /// Parse the serialized `NSAppleEventDescriptor` from
    /// `AppleScriptResult.success` into an adapter-specific observation.
    /// Returns nil if the descriptor shape doesn't match (graceful degrade
    /// against AS dictionary drift across macOS versions).
    func parse(_ descriptorData: Data, for bundleID: String) -> (any AdapterObservation)?

    /// Feed observation through the adapter's internal state machine.
    /// Returns 0..N `RawEvent` rows to enqueue.
    mutating func observe(
        _ observation: any AdapterObservation,
        nowMs: Int64,
        localAppsStore: LocalAppsStore
    ) -> [RawEvent]
}
