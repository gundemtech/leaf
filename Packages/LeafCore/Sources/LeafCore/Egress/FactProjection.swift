import Foundation

/// Allow-list projection for the LLM egress path (fail-closed). Maps a raw
/// event payload to OUTPUT-named, body-free fields. This is a *mapping*, not a
/// raw pass-through: scalar facts keep their raw names; the user's own
/// authored label (§4.3) is re-emitted under a distinct `self_authored_*` key.
///
/// Invariant: **no raw `EgressFactAllowlist.bodyFields` key ever appears as an
/// output key** — so "bodies never leak" holds unconditionally, even for the
/// self-authored carve-out (verified by `LLMEgressLeakageTests`).
public enum FactProjection {

  /// Project the event's payload. Unknown keys / kinds are dropped (fail-closed).
  /// - Parameters:
  ///   - strictMode: when true, self-authored labels are also dropped (§4.3
  ///     "строгий режим" — they move to escalation).
  ///   - authoredByViewer: explicit authorship signal. Self-authored labels go
  ///     ONLY when this is true; absent/false → treated as not-mine → dropped
  ///     (no inference "title == mine", no mis-attribution of others' content).
  public static func project(
    _ event: EgressEvent,
    strictMode: Bool,
    authoredByViewer: Bool
  ) -> [String: String] {
    var out: [String: String] = [:]

    // 1. Scalar facts pass through under their raw names.
    for (key, value) in event.payload where EgressFactAllowlist.scalarFacts.contains(key) {
      out[key] = value
    }

    // 2. Self-authored label carve-out (§4.3) — gated by kind + authorship + !strict.
    if !strictMode, authoredByViewer,
      let map = EgressFactAllowlist.selfAuthored[event.kind],
      let raw = event.payload[map.source], !raw.isEmpty {
      out[map.output] = String(raw.prefix(EgressFactAllowlist.selfAuthoredCap))
    }

    return out
  }
}
