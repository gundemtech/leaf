import Foundation

/// Phase Track-6 P5 — Public protocol for matching a Zoom meeting to a
/// concurrent calendar event. Returns SHA256(EKEvent.eventIdentifier)[:16]
/// hex string when an active event within ±15min of `atMs` carries a Zoom URL
/// in .location, .notes, or .url. Returns nil otherwise. Fail-closed —
/// no errors thrown; nil covers all failure modes (no permission, no match,
/// regex miss, identifier missing).
///
/// Production implementation lives in LeafCorePrivate (EventKit predicate +
/// URL regex + SHA256). LeafCore consumers use this protocol so the EventKit
/// dependency stays moat-side.
public protocol ZoomCalendarLinker: Sendable {
    func match(atMs: Int64) -> String?
}

/// Test/default no-op implementation. Always returns nil.
public struct NoOpZoomCalendarLinker: ZoomCalendarLinker {
    public init() {}
    public func match(atMs: Int64) -> String? { nil }
}
