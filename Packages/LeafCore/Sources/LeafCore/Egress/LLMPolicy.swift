import Foundation

public struct LLMPolicyConfig: Sendable {
  /// §4.3 "строгий режим": when true, the user's own authored labels are also
  /// withheld from the default path (they move to escalation).
  public let strictMode: Bool
  public init(strictMode: Bool = false) {
    self.strictMode = strictMode
  }
}

/// The cloud-LLM egress policy (Track AI Coworker §13.2). Enforces the three
/// buckets (§4.1) on the LLM path and is the sole constructor of the opaque
/// `PromptSafeContext`.
public struct LLMPolicy: EgressPolicy {
  private let moat: LLMEgressMoat
  private let config: LLMPolicyConfig

  public init(
    moat: LLMEgressMoat = .publicSubstrate,
    config: LLMPolicyConfig = .init()
  ) {
    self.moat = moat
    self.config = config
  }

  /// Bucket-1: events that must never leave the device (neither body nor
  /// app+time). Two signals in P0: a personal-app bundle ID (moat list) and a
  /// Slack DM (anonymized to the literal "DM" bucket at capture — its very
  /// existence + timing is bucket-1, so the whole event is dropped).
  private func isNeverToCloud(_ event: EgressEvent) -> Bool {
    if let bundleID = event.bundleID, moat.neverToCloudBundleIDs.contains(bundleID) {
      return true
    }
    if event.payload[Schema.EventPayloadKeys.channelName] == "DM" {
      return true
    }
    return false
  }

  public func project(_ event: EgressEvent) -> EgressEvent? {
    guard !isNeverToCloud(event) else { return nil }
    let fields = FactProjection.project(
      event,
      strictMode: config.strictMode,
      authoredByViewer: Self.authoredByViewer(event))
    return EgressEvent(
      timestamp: event.timestamp, kind: event.kind,
      bundleID: event.bundleID, payload: fields)
  }

  /// Build the opaque prompt-safe context. Bucket-1 events are omitted; events
  /// that project to no shareable field are also omitted (so a content-only
  /// event contributes no bare kind+time metadata).
  public func makeContext(events: [EgressEvent]) -> PromptSafeContext {
    let facts = events.compactMap { event -> ProjectedFact? in
      guard let projected = project(event), !projected.payload.isEmpty else { return nil }
      return ProjectedFact(
        kind: projected.kind,
        tsBucketMs: Int64(projected.timestamp.timeIntervalSince1970 * 1000),
        fields: projected.payload)
    }
    return PromptSafeContext(facts: facts)
  }

  /// P0 reads the explicit authorship signal from the payload. Per-source
  /// derivation (git-author match / GitHub `viewer_login`) is collector wiring
  /// in P1; absent → false → treated as not-mine (no inference, no
  /// mis-attribution).
  static func authoredByViewer(_ event: EgressEvent) -> Bool {
    event.payload["authored_by_viewer"] == "true"
  }
}
