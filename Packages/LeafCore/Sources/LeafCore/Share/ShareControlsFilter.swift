import Foundation

/// Per-user whitelist: what leaves this device, at what granularity, to teammates.
/// Applied in the Agent BEFORE encryption. The relay never sees the difference
/// between "filtered out" and "no event occurred".
public protocol ShareControlsFilter: Sendable {
    func filter(_ event: RawEvent) -> RawEvent?
    func maxGranularity(for bundleID: String) -> Granularity?
}

/// Phase-0 stub: passes everything through. The real filter lands in Phase 2.
public struct PassthroughShareControls: ShareControlsFilter {
    public init() {}
    public func filter(_ event: RawEvent) -> RawEvent? { event }
    public func maxGranularity(for bundleID: String) -> Granularity? { .l1 }
}
