import Foundation

/// Shared egress-policy seam (Track AI Coworker §13.2 — one egress core, two
/// policies). `project` returns the cloud-safe projection of an event, or `nil`
/// when the event must NEVER leave the device (bucket-1: personal apps/folders
/// — neither body nor app+time). The projected `EgressEvent.payload` carries
/// OUTPUT-named, allow-listed, body-free fields only.
///
/// P0 ships one conformance — `LLMPolicy` (the cloud-LLM path). A relay-path
/// adapter over the existing `TeamEventBroadcastService` pipeline is a later
/// phase; the dead `ShareControlsFilter` stub is intentionally left untouched.
public protocol EgressPolicy: Sendable {
  func project(_ event: EgressEvent) -> EgressEvent?
}
