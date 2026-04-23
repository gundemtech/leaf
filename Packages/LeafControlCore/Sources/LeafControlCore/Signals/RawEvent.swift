import Foundation

/// Сырой event после сборки коллектором в Agent, до применения Share Controls filter.
/// Storage-level identity (rowID) живёт в internal `EventRecord` — в RawEvent не торчит,
/// т.к. RawEvent это in-flight value, не durable handle.
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
