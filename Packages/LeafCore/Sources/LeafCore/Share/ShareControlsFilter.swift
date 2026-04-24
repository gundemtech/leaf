import Foundation

/// Per-user whitelist: what leaves this device, at what granularity, to teammates.
/// Applied в Agent ДО encryption. Relay никогда не видит разницу
/// "отфильтровано vs не было события".
public protocol ShareControlsFilter: Sendable {
    func filter(_ event: RawEvent) -> RawEvent?
    func maxGranularity(for bundleID: String) -> Granularity?
}

/// Phase-0 заглушка: пропускает всё. Реальный фильтр — Phase 2.
public struct PassthroughShareControls: ShareControlsFilter {
    public init() {}
    public func filter(_ event: RawEvent) -> RawEvent? { event }
    public func maxGranularity(for bundleID: String) -> Granularity? { .l1 }
}
