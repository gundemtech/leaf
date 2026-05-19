//
//  QueryTeamPayloadFilter.swift
//  LeafCore
//
//  Track 5 / S8 / T7 — Second-layer per-source payload allowlist applied
//  by the `leaf_query_team` MCP tool before returning a teammate timeline
//  to the AI client.
//
//  Why two layers?
//    Layer 1 — `TeamEventPayloadBuilder` filters the payload at broadcast
//              time (sender Mac → Supabase). The encrypted blob on the
//              relay contains only allowlisted keys.
//    Layer 2 — *this filter* re-applies the same allowlist at MCP read time.
//              Defence-in-depth against:
//                a) Future migrations that backfill legacy mirror rows
//                   captured under a wider allowlist;
//                b) Local code paths writing to `team_events_mirror` that
//                   bypass the broadcast filter (test fixtures, debug tools);
//                c) Bugs introducing banned keys during decryption / re-pack.
//
//  The MCP layer is the last guardrail before the payload leaves the Mac
//  and reaches the user's AI client (Claude Code / Cursor / etc.). Treat
//  this filter as load-bearing for ADR-010 even though Layer 1 also exists.
//
//  Lives in LeafCore (not LeafMCP) so SPM tests cover it directly — LeafMCP
//  is an Xcode target outside `swift test` (see GetCurrentPresenceTool.swift
//  for the same separation pattern).
//

import Foundation

public enum QueryTeamPayloadFilter {

    /// Apply per-source allowlist to a single event payload.
    ///
    /// - If `sourceKind` matches a known `ShareSource.rawValue`, keep only
    ///   keys present in `TeamEventPayloadBuilder.allowedKeys(for:)`.
    /// - If `sourceKind` is unknown (legacy / forward-compat / typo from a
    ///   future sender), drop the entire payload — DENY by default.
    /// - Nested values are surfaced verbatim only if their top-level key
    ///   passed the allowlist; the filter never recurses into nested
    ///   structures (allowlist contract is keyed on flat payload keys per
    ///   `TeamEventPayloadBuilder.allowedKeys`).
    public static func filter(
        _ payload: [String: AnyJSONValue],
        sourceKind: String
    ) -> [String: AnyJSONValue] {
        guard let source = ShareSource(rawValue: sourceKind) else {
            // Unknown source → empty payload. DENY default.
            return [:]
        }
        let allowed = TeamEventPayloadBuilder.allowedKeys(for: source)
        return payload.filter { allowed.contains($0.key) }
    }

    /// Apply the filter to a full timeline result. Replaces each event's
    /// payload with the allowlisted subset.
    public static func filter(
        _ result: TeamTimelineQueryService.TeamTimelineResult
    ) -> TeamTimelineQueryService.TeamTimelineResult {
        let filteredEvents = result.events.map { evt in
            TeamTimelineQueryService.TeamTimelineResult.Event(
                eventID: evt.eventID,
                kind: evt.kind,
                sourceKind: evt.sourceKind,
                tsMs: evt.tsMs,
                payload: filter(evt.payload, sourceKind: evt.sourceKind)
            )
        }
        return TeamTimelineQueryService.TeamTimelineResult(
            member: result.member,
            workspace: result.workspace,
            window: result.window,
            events: filteredEvents,
            totalCount: result.totalCount,
            truncated: result.truncated
        )
    }
}
