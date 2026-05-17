//
//  GoogleCalendarCollector+Helpers.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — pure helpers: domain extraction +
//  Any→String payload flattening + anchor timestamp resolution. Pure
//  relocation from GoogleCalendarCollector.swift.
//

import Foundation

extension GoogleCalendarCollector {
    /// Extract domain part from an email-shaped string. Returns nil if no
    /// `@` is present (e.g. integration `workspaceID` is not an email yet —
    /// edge case for legacy bootstraps).
    static func extractDomain(from email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...])
    }

    /// Flatten the mapper's `[String: Any]` dict into `[String: String]` for
    /// `RawEvent.payload`. Bool → "true"/"false" (matches Linear collector
    /// convention for `body_truncated` etc.). Int64/Int/Double → decimal
    /// string. Everything else → `String(describing:)`. Privacy: this layer
    /// never injects keys — it only converts whatever the mapper produced.
    static func flatten(_ dict: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(dict.count)
        for (key, value) in dict {
            switch value {
            case let s as String:
                out[key] = s
            case let b as Bool:
                out[key] = b ? "true" : "false"
            case let i as Int64:
                out[key] = String(i)
            case let i as Int:
                out[key] = String(i)
            case let d as Double:
                out[key] = String(d)
            default:
                out[key] = String(describing: value)
            }
        }
        return out
    }

    /// Timestamp anchor: prefer event.updated, fall back to start_ms, fall
    /// back to tick time. Stable timestamps matter for the chronological
    /// events index.
    static func anchorTimestamp(payload: [String: String], nowMs: Int64) -> Date {
        if let updated = payload["updated_ms"], let ms = Int64(updated) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        }
        if let start = payload["start_ms"], let ms = Int64(start) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        }
        return Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0)
    }
}
