//
//  QueryEngine+GetDecision.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — `getDecision` topic→event FTS lookup
//  + ranked-decision projection. Pure relocation from QueryEngine.swift.
//

import Foundation
import GRDB

extension QueryEngine {
    // MARK: - getDecision

    public func getDecision(topic: String, period: PeriodSpec?) throws -> GetDecisionResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> GetDecisionResponse in
            // Period defaults to the widest representable range when caller
            // doesn't scope; `EventsFullTextStore.search` filters by events.ts.
            let range: ClosedRange<Int64>
            if let p = period {
                range = p.startMs...p.endMs
            } else {
                range = Int64.min...Int64.max
            }

            // FTS over event bodies — events_fts is contentless over
            // `events.payload.body`, not `decisions.reasoning_excerpt`. Topic
            // match → candidate event ids → join to `decisions` table to find
            // the highest-confidence decision pinned to one of those events.
            let candidateIDs = try EventsFullTextStore.search(
                query: topic, period: range, limit: Self.decisionTopicCandidateLimit, in: rawDB
            )
            guard !candidateIDs.isEmpty else {
                return GetDecisionResponse(decision: nil, relatedEvents: [], truncationNote: nil)
            }

            let placeholders = Array(repeating: "?", count: candidateIDs.count).joined(separator: ",")
            let row = try Row.fetchOne(
                rawDB,
                sql: """
                        SELECT id, event_id, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms
                          FROM decisions
                         WHERE event_id IN (\(placeholders))
                         ORDER BY confidence DESC, detected_at_ms DESC
                         LIMIT 1
                    """, arguments: StatementArguments(candidateIDs))

            guard let row else {
                return GetDecisionResponse(decision: nil, relatedEvents: [], truncationNote: nil)
            }

            let decisionView = decisionView(from: row)
            let originatingEventID = decisionView.eventID
            let originatingEvent =
                try projectEvents(
                    eventIDs: [originatingEventID], in: rawDB
                ).first ?? Self.placeholderEvent(eventID: originatingEventID)

            // Outbound links from the originating event = pointers to
            // implementation (Linear ticket / GitHub PR / Slack thread).
            let linksFromOrigin = try EventLinksStore.linksFrom(eventID: originatingEventID, in: rawDB)
            let linkViews = linksFromOrigin.map(LinkView.init(from:))

            // Related events: every event that the originating event links TO
            // (forward) AND every event that shares those targets (siblings).
            // We approximate as "events linking to any of those targets" via
            // EventLinksStore.eventsLinkingTo.
            var relatedSet = Set<Int64>()
            for link in linksFromOrigin {
                let ids = try EventLinksStore.eventsLinkingTo(
                    targetKind: link.targetKind,
                    targetRef: link.targetRef,
                    period: nil,
                    in: rawDB
                )
                for id in ids where id != originatingEventID {
                    relatedSet.insert(id)
                }
            }
            let relatedEvents = try projectEvents(eventIDs: Array(relatedSet), in: rawDB)

            return GetDecisionResponse(
                decision: DecisionDetail(
                    decision: decisionView,
                    originatingEvent: originatingEvent,
                    linksToImplementation: linkViews
                ),
                relatedEvents: relatedEvents,
                truncationNote: nil
            )
        }
    }
}
