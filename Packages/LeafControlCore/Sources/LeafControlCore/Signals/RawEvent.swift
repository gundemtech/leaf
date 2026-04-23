import Foundation

/// Сырой event после сборки коллектором в Agent, до применения Share Controls filter.
public struct RawEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let signalType: SignalType
    public let bundleID: String?
    public let payload: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        signalType: SignalType,
        bundleID: String? = nil,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.signalType = signalType
        self.bundleID = bundleID
        self.payload = payload
    }
}
