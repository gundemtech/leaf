import Foundation
import GRDB

/// Phase 4.7.B — single point of write для `presence_state` table.
/// Idempotent UPSERT по `provider` PK. Каждый collector tick вызывает `upsert(...)`
/// один раз с current-state snapshot для своего provider'а; дополнительный
/// "derived" pseudo-provider зарезервирован для Phase 4.9 mode classifier.
///
/// ADR-010 redaction — caller responsibility: `state` уже должен быть
/// очищен от bodies/titles/PII до вызова. Этот helper не валидирует
/// содержимое словаря и не имеет доступа к Share Controls filter (тот
/// применяется отдельно в Agent broadcast path в Phase 5).
public struct PresenceStateWriter: Sendable {
    /// Ключи rows в `presence_state`. Расходится с `IntegrationProvider`
    /// (linear / github / slack), потому что у presence_state есть extra
    /// `derived` pseudo-row под Phase 4.9 mode classifier output.
    public enum Provider: String, Sendable, Hashable, CaseIterable {
        case github
        case linear
        case slack
        case derived
        case googleCalendar = "google_calendar"  // Track-6 P4
        /// Track-6 P5 — Zoom Deep presence row. State JSON shape:
        ///   { meeting_active: Bool, last_observed_at_ms: Int64,
        ///     meeting_started_at_ms?: Int64, cold_start?: Bool,
        ///     linked_calendar_event_id?: String }
        /// Transient fields (meeting_started_at_ms, cold_start, linked_calendar_event_id)
        /// are emitted only while meeting_active=true. ADR-010: no raw URLs, titles,
        /// participants, recording state.
        case zoom
    }

    /// UPSERT current-state snapshot. `state` сериализуется в JSON через
    /// `JSONSerialization` (sortedKeys → детерминированный layout для тестов
    /// и diffing). `derivedMode` всегда `nil` в Phase 4.7 — populated в 4.9.
    public static func upsert(
        provider: Provider,
        state: [String: Any],
        derivedMode: String? = nil,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        // Pre-validate: `JSONSerialization.data(withJSONObject:)` бросает
        // ObjC NSInvalidArgumentException (а не Swift error) если в словаре
        // встретится non-serializable значение (Date, Data, custom struct).
        // ObjC exception нельзя поймать в Swift через `try` — поэтому
        // защищаемся явным `isValidJSONObject` guard'ом до вызова.
        guard JSONSerialization.isValidJSONObject(state) else {
            throw LeafError.jsonEncodingFailed
        }
        let stateData: Data
        do {
            stateData = try JSONSerialization.data(
                withJSONObject: state,
                options: [.sortedKeys]
            )
        } catch {
            throw LeafError.jsonEncodingFailed
        }
        guard let stateString = String(data: stateData, encoding: .utf8) else {
            throw LeafError.jsonEncodingFailed
        }

        try db.execute(
            sql: """
                INSERT INTO \(Schema.PresenceState.tableName) (
                    \(Schema.PresenceState.provider),
                    \(Schema.PresenceState.stateJSON),
                    \(Schema.PresenceState.derivedMode),
                    \(Schema.PresenceState.updatedAtMs)
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(Schema.PresenceState.provider)) DO UPDATE SET
                    \(Schema.PresenceState.stateJSON)   = excluded.\(Schema.PresenceState.stateJSON),
                    \(Schema.PresenceState.derivedMode) = excluded.\(Schema.PresenceState.derivedMode),
                    \(Schema.PresenceState.updatedAtMs) = excluded.\(Schema.PresenceState.updatedAtMs)
                """,
            arguments: [provider.rawValue, stateString, derivedMode, nowMs]
        )
    }

    /// Reader для одного provider'а. Returns `nil` если row отсутствует —
    /// MCP tools интерпретируют как "provider ещё не отчитывался".
    public static func read(
        provider: Provider,
        in db: GRDB.Database
    ) throws -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.PresenceState.stateJSON),
                       \(Schema.PresenceState.derivedMode),
                       \(Schema.PresenceState.updatedAtMs)
                FROM \(Schema.PresenceState.tableName)
                WHERE \(Schema.PresenceState.provider) = ?
                """,
            arguments: [provider.rawValue]
        )
        guard let row else { return nil }
        return try mapRow(row)
    }

    /// Reader для всех provider'ов — bulk fetch для merged snapshot
    /// (`get_current_presence` MCP tool, Phase 4.7.B-15).
    public static func readAll(
        in db: GRDB.Database
    ) throws -> [Provider: (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.PresenceState.provider),
                       \(Schema.PresenceState.stateJSON),
                       \(Schema.PresenceState.derivedMode),
                       \(Schema.PresenceState.updatedAtMs)
                FROM \(Schema.PresenceState.tableName)
                """
        )
        var result: [Provider: (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)] = [:]
        for row in rows {
            guard
                let providerRaw = row[Schema.PresenceState.provider] as String?,
                let provider = Provider(rawValue: providerRaw)
            else { continue }
            result[provider] = try mapRow(row)
        }
        return result
    }

    /// DELETE by provider — вызывается при integration disconnect, чтобы
    /// merged snapshot не показывал stale presence от провайдера, для
    /// которого юзер только что revoked OAuth.
    public static func delete(
        provider: Provider,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.PresenceState.tableName)
                WHERE \(Schema.PresenceState.provider) = ?
                """,
            arguments: [provider.rawValue]
        )
    }

    // MARK: - Zoom (Track-6 P5)

    /// Build the `state` dict for a `.zoom` presence row. Transient fields
    /// (started_at_ms / cold_start / linked_calendar_event_id) are present only
    /// when `meetingActive == true`. ADR-010: raw URLs / titles / participants
    /// / recording state never appear — caller passes only the SHA256 hash of
    /// the matched calendar event identifier (16-hex-char shape).
    public static func buildZoomState(
        meetingActive: Bool,
        meetingStartedAtMs: Int64?,
        coldStart: Bool?,
        linkedCalendarEventID: String?,
        lastObservedAtMs: Int64
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "meeting_active": meetingActive,
            "last_observed_at_ms": lastObservedAtMs,
        ]
        if meetingActive {
            if let started = meetingStartedAtMs { dict["meeting_started_at_ms"] = started }
            if let cold = coldStart { dict["cold_start"] = cold }
            if let id = linkedCalendarEventID, !id.isEmpty {
                dict["linked_calendar_event_id"] = id
            }
        }
        return dict
    }

    // MARK: - Private

    private static func mapRow(
        _ row: Row
    ) throws -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64) {
        guard
            let stateString = row[Schema.PresenceState.stateJSON] as String?,
            let updatedAtMs = row[Schema.PresenceState.updatedAtMs] as Int64?
        else { throw LeafError.invalidPayload }

        let stateData = Data(stateString.utf8)
        let parsed = try JSONSerialization.jsonObject(with: stateData, options: [])
        guard let state = parsed as? [String: Any] else {
            throw LeafError.invalidPayload
        }

        let derivedMode = row[Schema.PresenceState.derivedMode] as String?
        return (state: state, derivedMode: derivedMode, updatedAtMs: updatedAtMs)
    }
}
