//
//  GoogleCalendarAPIClient.swift
//  LeafCore
//
//  Track-6 P4 — Google Calendar v3 REST surface: events.list (sync-token
//  driven) + calendarList.list + calendarList.get(primary) identity capture.
//  Spec §1.1 (events.list), §1.2 (sync semantics), §1.5 (calendarList),
//  §3.4 (410 fullSyncRequired recovery), §7.3 (identity capture).
//
//  Protocol-based for mockability via URLProtocol-stubbed URLSession (same
//  pattern as GoogleCalendarOAuthClient). Stub lives in tests target.
//
//  ADR-010 boundary: this client decodes ALL fields Google returns —
//  including bodies/locations/attendee PII — but the upstream mapper
//  (GoogleCalendarEventMapper) drops them before any payload reaches the DB.
//  Privacy is enforced one layer up; this layer is a faithful transport.
//
//  Retry/backoff policy is intentionally NOT here. .rateLimited is thrown
//  raw and the collector tick (Task 13+) decides next-tick scheduling.
//

import Foundation

// MARK: - Protocol

/// Google Calendar v3 surface required by the polling collector.
public protocol GoogleCalendarAPIClient: Sendable {
    /// events.list per spec §1.1. Bootstrap (no `syncToken`) MUST set
    /// `bootstrapTimeMin` + `singleEvents=true` + `showDeleted=true` so the
    /// initial sweep yields an expanded recurrence series. Subsequent ticks
    /// pass the saved `syncToken` and Google returns only delta.
    ///
    /// 410 with `errors[0].reason == "fullSyncRequired"` throws
    /// `.fullSyncRequired`; caller drops the saved syncToken and restarts
    /// with bootstrap shape per spec §3.4.
    func eventsList(
        calendarID: String,
        syncToken: String?,
        bootstrapTimeMin: Date?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.EventsListResponse

    /// calendarList.list — discover subscribed calendars (spec §1.5).
    func calendarListList(
        syncToken: String?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListResponse

    /// calendarList.get(calendarId=primary) — identity capture per spec §7.3.
    /// Returns the primary calendar entry; `.id` is the authenticated user's
    /// email and serves as the stable account identifier.
    func calendarListGetPrimary(
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListEntry
}

// MARK: - Errors

public enum GoogleCalendarAPIError: Error, Sendable, Equatable {
    /// 401 — access token expired or revoked; caller refreshes + retries.
    case unauthorized
    /// 410 with `reason == "fullSyncRequired"` — saved syncToken stale;
    /// caller drops it and restarts with bootstrap shape (spec §3.4).
    case fullSyncRequired
    /// 404 — calendar no longer accessible (unsubscribed / deleted).
    case notFound
    /// 429, or 403 with userRateLimitExceeded / rateLimitExceeded reason.
    /// `retryAfterSec` is the value of the Retry-After header when present.
    case rateLimited(retryAfterSec: Int?)
    /// Any other non-2xx status. Body included verbatim (best-effort UTF-8).
    case http(statusCode: Int, body: String?)
    /// JSONDecoder failure — `String(describing:)` of the underlying error
    /// (Equatable-friendly).
    case decoding(String)
    /// URLSession transport failure (network down, DNS, TLS, etc.).
    case transport(String)
}

// MARK: - Concrete URLSession impl

public struct ProdGoogleCalendarAPIClient: GoogleCalendarAPIClient {
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    // MARK: events.list

    public func eventsList(
        calendarID: String,
        syncToken: String?,
        bootstrapTimeMin: Date?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.EventsListResponse {
        // URL: /calendar/v3/calendars/<id>/events
        // <id> may contain '@' / '/' — encode via URLComponents path so
        // disallowed chars are percent-escaped consistently.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/calendar/v3/calendars/\(calendarID)/events"

        var items: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        if let syncToken {
            // Subsequent: server enforces "no other params" — singleEvents /
            // showDeleted / timeMin would 400. Only syncToken + pageToken
            // are valid alongside.
            items.append(URLQueryItem(name: "syncToken", value: syncToken))
        } else {
            // Bootstrap: per spec §1.2 we want expanded singleton events
            // and tombstones for cancellations, anchored at bootstrapTimeMin.
            items.append(URLQueryItem(name: "singleEvents", value: "true"))
            items.append(URLQueryItem(name: "showDeleted", value: "true"))
            if let bootstrapTimeMin {
                items.append(URLQueryItem(name: "timeMin", value: Self.rfc3339(bootstrapTimeMin)))
            }
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw GoogleCalendarAPIError.transport("invalid URL components")
        }
        return try await get(url: url, accessToken: accessToken)
    }

    // MARK: calendarList.list

    public func calendarListList(
        syncToken: String?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/calendar/v3/users/me/calendarList"

        var items: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: "250"),
            URLQueryItem(name: "showHidden", value: "true"),
        ]
        if let syncToken {
            items.append(URLQueryItem(name: "syncToken", value: syncToken))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw GoogleCalendarAPIError.transport("invalid URL components")
        }
        return try await get(url: url, accessToken: accessToken)
    }

    // MARK: calendarList.get(primary)

    public func calendarListGetPrimary(
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListEntry {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary")!
        return try await get(url: url, accessToken: accessToken)
    }

    // MARK: - Internal: single GET + error classification

    private func get<T: Decodable>(url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw GoogleCalendarAPIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarAPIError.transport("non-HTTP response")
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw GoogleCalendarAPIError.decoding(String(describing: error))
            }
        }

        // Non-2xx: parse envelope to extract reason for 410/403 classification.
        let envelope = try? decoder.decode(GoogleCalendarAPI.ErrorEnvelope.self, from: data)
        let firstReason = envelope?.error.errors?.first?.reason

        switch http.statusCode {
        case 401:
            throw GoogleCalendarAPIError.unauthorized
        case 404:
            throw GoogleCalendarAPIError.notFound
        case 410 where firstReason == "fullSyncRequired":
            throw GoogleCalendarAPIError.fullSyncRequired
        case 429:
            throw GoogleCalendarAPIError.rateLimited(retryAfterSec: Self.retryAfter(http))
        case 403 where firstReason == "rateLimitExceeded" || firstReason == "userRateLimitExceeded":
            throw GoogleCalendarAPIError.rateLimited(retryAfterSec: Self.retryAfter(http))
        default:
            throw GoogleCalendarAPIError.http(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    // ISO8601DateFormatter is thread-safe for format-only use (no mutation
    // after init); marked nonisolated(unsafe) per Swift 6 concurrency rules.
    nonisolated(unsafe) private static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func rfc3339(_ date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }
}
