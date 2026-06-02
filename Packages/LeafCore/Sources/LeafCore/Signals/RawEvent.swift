import Foundation

/// Raw event after a collector assembles it in the Agent, before the Share Controls filter is applied.
/// Storage-level identity (rowID) lives in the internal `EventRecord` — it is not exposed on RawEvent,
/// because RawEvent is an in-flight value, not a durable handle.
public struct RawEvent: Codable, Sendable, Hashable {
    public let timestamp: Date
    public let signalType: SignalType
    public let bundleID: String?
    public let payload: [String: String]

    public init(
        timestamp: Date = Date(),
        signalType: SignalType,
        bundleID: String? = nil,
        payload: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.signalType = signalType
        self.bundleID = bundleID
        self.payload = payload
    }
}
