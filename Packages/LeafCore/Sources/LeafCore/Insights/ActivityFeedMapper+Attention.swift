import Foundation

extension ActivityFeedMapper {
    // MARK: - Attention (local app-switch)

    static func mapAttention(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let kind = payload["event_kind"] ?? "app_active"
        // Phase 4.10.B will add window_title / browser_url to attention payloads;
        // the mapper falls back to bundle name when absent.
        let title = sanitize(payload["window_title"]).flatMap { $0.isEmpty ? nil : $0 }
        let url = sanitize(payload["browser_url"]).flatMap { $0.isEmpty ? nil : $0 }
        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .local,
            eventKind: kind,
            primaryText: title ?? bundleID,
            secondaryText: url,
            bundleID: bundleID
        )
    }
}
