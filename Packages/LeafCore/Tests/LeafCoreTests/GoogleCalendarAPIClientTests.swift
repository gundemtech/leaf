// Track-6 P4 Task 11 — GoogleCalendarAPIClient tests.
// Prod URLSession impl tested via URLProtocol-stubbed ephemeral session
// (same pattern as GoogleCalendarOAuthClientTests). Stub round-trip tests
// verify enqueue ordering + call-log instrumentation.

import Foundation
import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

private final class GoogleCalendarAPIMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GoogleCalendarAPIClientTests: XCTestCase {

    private func makeClient() -> ProdGoogleCalendarAPIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GoogleCalendarAPIMockURLProtocol.self]
        return ProdGoogleCalendarAPIClient(urlSession: URLSession(configuration: cfg))
    }

    private func httpResponse(
        url: URL, status: Int, headers: [String: String] = ["Content-Type": "application/json"]
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    override func tearDown() async throws {
        GoogleCalendarAPIMockURLProtocol.handler = nil
    }

    // MARK: - Prod: bootstrap vs subsequent URL composition

    func testEventsListBootstrapSendsCorrectParams() async throws {
        var capturedURL: URL?
        let canned = #"{"items":[],"nextPageToken":null,"nextSyncToken":"sync-1"}"#
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            capturedURL = req.url
            return (self.httpResponse(url: req.url!, status: 200), Data(canned.utf8))
        }

        let client = makeClient()
        let bootstrapTime = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await client.eventsList(
            calendarID: "primary",
            syncToken: nil,
            bootstrapTimeMin: bootstrapTime,
            pageToken: nil,
            accessToken: "ya29.tok"
        )

        let urlStr = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(urlStr.contains("calendar/v3/calendars/primary/events"), "url=\(urlStr)")
        XCTAssertTrue(urlStr.contains("singleEvents=true"), "url=\(urlStr)")
        XCTAssertTrue(urlStr.contains("showDeleted=true"), "url=\(urlStr)")
        XCTAssertTrue(urlStr.contains("timeMin="), "url=\(urlStr)")
        XCTAssertTrue(urlStr.contains("maxResults=2500"), "url=\(urlStr)")
        XCTAssertFalse(urlStr.contains("syncToken="), "bootstrap MUST NOT send syncToken; url=\(urlStr)")
    }

    func testEventsListSubsequentSendsSyncToken() async throws {
        var capturedURL: URL?
        let canned = #"{"items":[],"nextPageToken":null,"nextSyncToken":"sync-2"}"#
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            capturedURL = req.url
            return (self.httpResponse(url: req.url!, status: 200), Data(canned.utf8))
        }

        let client = makeClient()
        _ = try await client.eventsList(
            calendarID: "primary",
            syncToken: "saved-sync-1",
            bootstrapTimeMin: nil,
            pageToken: nil,
            accessToken: "ya29.tok"
        )

        let urlStr = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(urlStr.contains("syncToken=saved-sync-1"), "url=\(urlStr)")
        XCTAssertFalse(urlStr.contains("singleEvents="), "subsequent MUST NOT send singleEvents; url=\(urlStr)")
        XCTAssertFalse(urlStr.contains("showDeleted="), "subsequent MUST NOT send showDeleted; url=\(urlStr)")
        XCTAssertFalse(urlStr.contains("timeMin="), "subsequent MUST NOT send timeMin; url=\(urlStr)")
    }

    // MARK: - Prod: decode + auth header

    func testEventsList200DecodesResponse() async throws {
        let canned = #"""
            {
              "kind": "calendar#events",
              "summary": "demidovdmitry07@gmail.com",
              "timeZone": "Europe/Berlin",
              "accessRole": "owner",
              "items": [
                {"id": "evt-1", "iCalUID": "u1", "status": "confirmed", "summary": "Standup"}
              ],
              "nextPageToken": "p2",
              "nextSyncToken": "sync-new"
            }
            """#
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.tok")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
            return (self.httpResponse(url: req.url!, status: 200), Data(canned.utf8))
        }

        let client = makeClient()
        let resp = try await client.eventsList(
            calendarID: "primary",
            syncToken: "x",
            bootstrapTimeMin: nil,
            pageToken: nil,
            accessToken: "ya29.tok"
        )
        XCTAssertEqual(resp.items.count, 1)
        XCTAssertEqual(resp.items.first?.id, "evt-1")
        XCTAssertEqual(resp.nextSyncToken, "sync-new")
        XCTAssertEqual(resp.nextPageToken, "p2")
    }

    // MARK: - Prod: error classification

    func testEventsList410FullSyncRequiredThrows() async throws {
        let body = #"""
            {"error":{"code":410,"message":"Sync token is no longer valid","errors":[{"reason":"fullSyncRequired","domain":"calendar"}]}}
            """#
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            (self.httpResponse(url: req.url!, status: 410), Data(body.utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.eventsList(
                calendarID: "primary",
                syncToken: "stale",
                bootstrapTimeMin: nil,
                pageToken: nil,
                accessToken: "tok"
            )
            XCTFail("Expected .fullSyncRequired")
        } catch let err as GoogleCalendarAPIError {
            XCTAssertEqual(err, .fullSyncRequired)
        }
    }

    func testEventsList401ThrowsUnauthorized() async throws {
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            (self.httpResponse(url: req.url!, status: 401), Data(#"{"error":{"code":401,"message":"unauth"}}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.eventsList(
                calendarID: "primary", syncToken: nil,
                bootstrapTimeMin: Date(), pageToken: nil, accessToken: "expired"
            )
            XCTFail("Expected .unauthorized")
        } catch let err as GoogleCalendarAPIError {
            XCTAssertEqual(err, .unauthorized)
        }
    }

    func testEventsList404ThrowsNotFound() async throws {
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            (self.httpResponse(url: req.url!, status: 404), Data(#"{"error":{"code":404,"message":"gone"}}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.eventsList(
                calendarID: "removed@group.calendar.google.com",
                syncToken: "x", bootstrapTimeMin: nil, pageToken: nil, accessToken: "tok"
            )
            XCTFail("Expected .notFound")
        } catch let err as GoogleCalendarAPIError {
            XCTAssertEqual(err, .notFound)
        }
    }

    func testEventsList429ThrowsRateLimitedWithRetryAfter() async throws {
        GoogleCalendarAPIMockURLProtocol.handler = { req in
            let headers: [String: String] = ["Content-Type": "application/json", "Retry-After": "42"]
            return (
                self.httpResponse(url: req.url!, status: 429, headers: headers),
                Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
            )
        }
        let client = makeClient()
        do {
            _ = try await client.eventsList(
                calendarID: "primary", syncToken: "x",
                bootstrapTimeMin: nil, pageToken: nil, accessToken: "tok"
            )
            XCTFail("Expected .rateLimited")
        } catch let err as GoogleCalendarAPIError {
            XCTAssertEqual(err, .rateLimited(retryAfterSec: 42))
        }
    }

    // MARK: - Stub: round-trip

    func testStubEnqueuedResponsesReturnedInOrder() async throws {
        let stub = StubGoogleCalendarAPIClient()
        let r1 = GoogleCalendarAPI.EventsListResponse(
            kind: nil, summary: nil, timeZone: nil, accessRole: nil,
            items: [], nextPageToken: "page-2", nextSyncToken: nil
        )
        let r2 = GoogleCalendarAPI.EventsListResponse(
            kind: nil, summary: nil, timeZone: nil, accessRole: nil,
            items: [], nextPageToken: nil, nextSyncToken: "sync-final"
        )
        await stub.enqueueEventsList(r1)
        await stub.enqueueEventsList(r2)

        let got1 = try await stub.eventsList(
            calendarID: "primary", syncToken: nil, bootstrapTimeMin: Date(),
            pageToken: nil, accessToken: "tok"
        )
        let got2 = try await stub.eventsList(
            calendarID: "primary", syncToken: nil, bootstrapTimeMin: Date(),
            pageToken: "page-2", accessToken: "tok"
        )
        XCTAssertEqual(got1.nextPageToken, "page-2")
        XCTAssertEqual(got2.nextSyncToken, "sync-final")
    }

    func testStubLogsCallSignatures() async throws {
        let stub = StubGoogleCalendarAPIClient()
        let r1 = GoogleCalendarAPI.EventsListResponse(
            kind: nil, summary: nil, timeZone: nil, accessRole: nil,
            items: [], nextPageToken: nil, nextSyncToken: "s"
        )
        await stub.enqueueEventsList(r1)
        _ = try await stub.eventsList(
            calendarID: "cal-abc", syncToken: "tok-1",
            bootstrapTimeMin: nil, pageToken: "p9", accessToken: "tok"
        )
        let calls = await stub.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("eventsList"))
        XCTAssertTrue(calls[0].contains("cal-abc"))
        XCTAssertTrue(calls[0].contains("tok-1"))
        XCTAssertTrue(calls[0].contains("p9"))
    }
}
// swiftlint:enable force_unwrapping
