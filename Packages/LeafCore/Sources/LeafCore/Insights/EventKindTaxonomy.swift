import Foundation

/// Use-case rebuild Track A4 — shared feed-worthiness classification.
///
/// The events table mixes three very different populations: substance (the
/// user's actual work output — commits, PRs, issues, messages, AI sessions),
/// recurring state pulses (provider counters, system transitions, raw
/// attention pings) and pure diagnostics (token accounting). Surfaces that
/// show "what happened" (activity feed, Search, MCP query responses, Brief)
/// must agree on what counts as noise — before A4 each surface either showed
/// everything (pulse spam drowned the signal) or invented its own list.
///
/// Unknown kinds default to SUBSTANCE — a new collector's events must never
/// silently vanish from feeds because nobody registered them here.
public enum FeedClass: Sendable, Equatable {
  /// Work output — feed-worthy.
  case substance
  /// Recurring state observation (counters, transitions, raw attention pings).
  case statePulse
  /// Internal accounting (token usage) — never user-facing.
  case diagnostic
}

public enum EventKindTaxonomy {

  /// Internal accounting kinds.
  private static let diagnosticKinds: Set<String> = [
    "claude_tokens_used"
  ]

  /// Explicit state-pulse kinds that no suffix rule catches.
  private static let statePulseKinds: Set<String> = [
    "gh_check_runs_status",
    "gh_pr_titles_backfill",
    "space_switched",
    "system_woke",
    "system_slept",
    "system_locked",
    "system_unlocked",
    "audio_route_changed",
    "display_configuration_changed",
    "wifi_network_changed",
    "vpn_state_changed",
    "mic_in_use_changed",
    "intensity_minute_aggregate",
  ]

  public static func feedClass(eventKind: String?, signalType: String?) -> FeedClass {
    guard let kind = eventKind, !kind.isEmpty else {
      // Bare attention pings (frontmost-app observations carry no event_kind).
      // Their aggregates surface via timeline/insights; in feed surfaces the
      // raw pings are noise.
      return signalType == "attention" ? .statePulse : .substance
    }
    if diagnosticKinds.contains(kind) { return .diagnostic }
    if statePulseKinds.contains(kind) { return .statePulse }
    if kind.hasSuffix("_pulse") || kind.hasSuffix("_count") { return .statePulse }
    return .substance
  }

  /// SQL fragment selecting substance rows only — MUST mirror `feedClass`
  /// (parity test enforces). `column` prefixes let callers alias the events
  /// table.
  public static func substanceSQLPredicate(
    signalTypeColumn: String = "signal_type",
    payloadColumn: String = "payload_json"
  ) -> String {
    let explicitNoise = diagnosticKinds.union(statePulseKinds)
      .sorted()
      .map { "'\($0)'" }
      .joined(separator: ", ")
    return """
      NOT (
        (\(signalTypeColumn) = 'attention'
          AND json_extract(\(payloadColumn), '$.event_kind') IS NULL)
        OR json_extract(\(payloadColumn), '$.event_kind') IN (\(explicitNoise))
        OR json_extract(\(payloadColumn), '$.event_kind') LIKE '%\\_pulse' ESCAPE '\\'
        OR json_extract(\(payloadColumn), '$.event_kind') LIKE '%\\_count' ESCAPE '\\'
      )
      """
  }
}
