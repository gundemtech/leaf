//
//  GitHubWarmCollector.swift
//  LeafCore
//
//  Phase Track-3 D2 — GitHub warm-tier (15m) collector. Mirrors
//  LinearWarmCollector shape. Full implementation lands in Task 8; this file
//  ships only the pure projectsV2Diff helper consumed by Task 8's tick logic.
//

import Foundation

/// Phase Track-3 D2 — GitHub warm-tier (15m) collector. Mirrors LinearWarmCollector
/// shape. Full implementation lands in Task 8; this file ships only the pure
/// projectsV2Diff helper consumed by Task 8's tick logic.
public actor GitHubWarmCollector {
    public init() {} // Placeholder — fleshed out in Task 8.

    /// Diffs two ProjectsV2 item snapshot arrays into three categorized lists:
    /// card moves (status changes), iteration changes, and field value updates.
    ///
    /// Bootstrap discipline: items present in `current` but absent from `prior`
    /// produce ZERO diff rows here — emit-on-first-sight is the collector tier's
    /// job (Task 8). This helper only reports state transitions for items the
    /// caller has already seen.
    ///
    /// Output is sorted by `itemID` (and by field name within the field-updated
    /// list) for deterministic test assertions and stable downstream ordering.
    public static func projectsV2Diff(
        prior: [GitHubProjectV2ItemSnapshot],
        current: [GitHubProjectV2ItemSnapshot]
    ) -> (cardMoved: [(String, String, String?, String?)],
          iterationChanged: [(String, String, String?, String?)],
          fieldUpdated: [(String, String, String, String?, String?)]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.itemID, $0) })
        var cardMoved: [(String, String, String?, String?)] = []
        var iter: [(String, String, String?, String?)] = []
        var fields: [(String, String, String, String?, String?)] = []
        for curr in current {
            guard let p = priorByID[curr.itemID] else { continue }  // new item — bootstrap discipline at collector tier
            if p.status != curr.status {
                cardMoved.append((curr.itemID, curr.projectID, p.status, curr.status))
            }
            if p.iterationID != curr.iterationID {
                iter.append((curr.itemID, curr.projectID, p.iterationID, curr.iterationID))
            }
            // Compare fieldValues per field name across union(prior, current).
            let allFieldNames = Set(p.fieldValues.keys).union(curr.fieldValues.keys)
            for name in allFieldNames.sorted() {
                let oldV = p.fieldValues[name]
                let newV = curr.fieldValues[name]
                if oldV != newV {
                    fields.append((curr.itemID, curr.projectID, name, oldV, newV))
                }
            }
        }
        return (cardMoved.sorted(by: { $0.0 < $1.0 }),
                iter.sorted(by: { $0.0 < $1.0 }),
                fields.sorted(by: { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }))
    }
}
