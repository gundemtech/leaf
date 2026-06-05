import Foundation

/// Neutral in-flight value the egress policies operate on. Built from a
/// collector `RawEvent` (P0 tests) or, in P1, from a stored event selected by
/// the QueryEngine. Kept distinct from `RawEvent` (the collector's in-flight
/// type) so the LLM egress boundary does not couple to the collector pipeline,
/// and so the same policy can later project stored events without a refactor.
public struct EgressEvent: Sendable, Equatable {
  public let timestamp: Date
  /// Discriminator for projection: `event_kind` from the payload when present,
  /// else the signal type's raw value.
  public let kind: String
  public let bundleID: String?
  public let payload: [String: String]

  public init(
    timestamp: Date,
    kind: String,
    bundleID: String?,
    payload: [String: String]
  ) {
    self.timestamp = timestamp
    self.kind = kind
    self.bundleID = bundleID
    self.payload = payload
  }

  /// Adapter from a collector `RawEvent`.
  public init(raw: RawEvent) {
    self.timestamp = raw.timestamp
    self.kind = raw.payload["event_kind"] ?? raw.signalType.rawValue
    self.bundleID = raw.bundleID
    self.payload = raw.payload
  }
}

extension EgressEvent: CustomStringConvertible {
  /// Redacted description — prints payload key NAMES only, never values.
  /// Raw event content must never reach logs/telemetry on the LLM path
  /// (audit H3): an un-projected `EgressEvent` carries bodies, so its default
  /// string form is deliberately value-free.
  public var description: String {
    let keys = payload.keys.sorted().joined(separator: ",")
    return "EgressEvent(kind: \(kind), bundleID: \(bundleID ?? "nil"), payloadKeys: [\(keys)])"
  }
}
