// Track 5 / S7 C.7 — CrossPostLogReader @Observable cache tests.
//
// Uses a stub SupabaseClient (via URLSession mock) that returns canned rows
// or throws. CrossPostLogReader is @MainActor; tests run on the main actor.

import XCTest
import CryptoKit
@testable import LeafCore

@MainActor
final class CrossPostLogReaderTests: XCTestCase {

    // MARK: - Helpers

    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey  = String(repeating: "42", count: 32)
    private let userID  = "00000000-0000-0000-0000-000000000fff"

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
        let bytes = Data(repeating: 0x42, count: 32)
        return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
    }

    private func makeJWT() -> String {
        let header  = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    /// Bootstrap handler wraps the mock so ensureAuthenticated() completes.
    private func wrapWithBootstrap(
        _ next: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
    ) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
        let jwt = makeJWT()
        let uid = userID
        return { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "ref",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                return next(request, body)
            }
        }
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
    }

    private func makeRow(
        messageID: String,
        platform: String = "slack",
        externalRef: String = "#leaf-architecture",
        externalURL: URL = URL(string: "https://slack.com/archives/C12345/p1716900000")!,
        postedAtMs: Int64 = 1_716_900_000_000,
        errorText: String? = nil
    ) throws -> CrossPostLogRow {
        try CrossPostLogRow(
            messageID: messageID,
            platform: platform,
            externalRef: externalRef,
            externalURL: externalURL,
            postedAtMs: postedAtMs,
            errorText: errorText
        )
    }

    /// Build a single-row JSON for a given messageID and platform.
    /// `nonisolated` so it can be called from `@Sendable` MockURLProtocol handlers.
    private nonisolated static func jsonRows(messageID: String, platform: String = "slack") -> Data {
        """
        [{
          "message_id": "\(messageID)",
          "platform": "\(platform)",
          "external_ref": "#leaf-architecture",
          "external_url": "https://slack.com/archives/C12345/p1716900000",
          "posted_at_ms": 1716900000000,
          "error_text": null
        }]
        """.data(using: .utf8)!
    }

    // MARK: - Tests

    // 1. Initial state is .idle.
    func testInitialState_Idle() {
        let reader = CrossPostLogReader(supabase: makeClient())
        if case .idle = reader.state { /* pass */ } else {
            XCTFail("expected .idle, got \(reader.state)")
        }
    }

    // 2. loadForMessages([]) → no-op; state stays .idle.
    func testLoadForMessages_Empty_NoOp() async {
        MockURLProtocol.handler = { _, _ in
            XCTFail("loadForMessages([]) must not fire network")
            return (HTTPURLResponse(url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        await reader.loadForMessages([])
        if case .idle = reader.state { /* pass */ } else {
            XCTFail("expected .idle after empty call, got \(reader.state)")
        }
    }

    // 3. loadForMessages with new IDs → fetches + caches; state → .loaded.
    func testLoadForMessages_NewIDs_FetchesAndCaches() async {
        let msgID = "msg-new"
        MockURLProtocol.handler = wrapWithBootstrap { _, _ in
            return (HTTPURLResponse(url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.jsonRows(messageID: msgID))
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        await reader.loadForMessages([msgID])

        guard case .loaded(let byID) = reader.state else {
            XCTFail("expected .loaded, got \(reader.state)"); return
        }
        XCTAssertNotNil(byID[msgID], "cache must contain entry for \(msgID)")
        XCTAssertEqual(byID[msgID]?.count, 1)
    }

    // 4. loadForMessages with all-cached IDs → no fetch; state → .loaded from cache.
    func testLoadForMessages_AllCached_NoFetch() async {
        let msgID = "msg-cached"
        nonisolated(unsafe) var crossPostFetchCount = 0
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            if request.url?.path == "/rest/v1/cross_post_log" {
                crossPostFetchCount += 1
            }
            return (HTTPURLResponse(url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.jsonRows(messageID: msgID))
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        // First call populates cache.
        await reader.loadForMessages([msgID])
        let callsAfterFirst = crossPostFetchCount

        // Second call — all cached; must not fire another network request.
        await reader.loadForMessages([msgID])
        XCTAssertEqual(crossPostFetchCount, callsAfterFirst,
                       "second loadForMessages call with all-cached IDs must not fire another fetch")
        if case .loaded = reader.state { /* pass */ } else {
            XCTFail("expected .loaded after all-cached call, got \(reader.state)")
        }
    }

    // 5. loadForMessages with mixed cached/missing → fetches only the missing IDs.
    func testLoadForMessages_MixedCachedAndMissing_FetchesOnlyMissing() async {
        let cachedID  = "msg-A"
        let missingID = "msg-B"
        nonisolated(unsafe) var capturedURLs: [URL] = []

        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            if request.url?.path == "/rest/v1/cross_post_log" {
                capturedURLs.append(request.url!)
            }
            // Return rows for whichever ID is requested.
            let id = request.url?.query?.contains(cachedID) == true ? cachedID : missingID
            return (HTTPURLResponse(url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.jsonRows(messageID: id))
        }
        let reader = CrossPostLogReader(supabase: makeClient())

        // Pre-populate cache for cachedID.
        await reader.loadForMessages([cachedID])
        let fetchCountAfterFirst = capturedURLs.count

        // Now request both; only missingID should be fetched.
        await reader.loadForMessages([cachedID, missingID])

        // The second fetch's URL must contain missingID but NOT cachedID.
        XCTAssertEqual(capturedURLs.count, fetchCountAfterFirst + 1,
                       "exactly one new fetch should fire for the missing ID")
        if let lastURL = capturedURLs.last {
            let query = lastURL.query ?? ""
            XCTAssertTrue(query.contains(missingID),
                          "fetch query must include missingID '\(missingID)', got: \(query)")
            XCTAssertFalse(query.contains(cachedID),
                           "fetch query must NOT include already-cached '\(cachedID)', got: \(query)")
        }
    }

    // 6. crossPosts(for:) returns cached rows for a known ID.
    func testCrossPosts_ReturnsForKnownID() async {
        let msgID = "msg-cp"
        MockURLProtocol.handler = wrapWithBootstrap { _, _ in
            return (HTTPURLResponse(url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.jsonRows(messageID: msgID))
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        await reader.loadForMessages([msgID])

        let rows = reader.crossPosts(for: msgID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.messageID, msgID)
    }

    // 7. crossPosts(for:) returns [] for unknown ID (no crash).
    func testCrossPosts_ReturnsEmptyForUnknownID() {
        let reader = CrossPostLogReader(supabase: makeClient())
        let rows = reader.crossPosts(for: "nonexistent-msg")
        XCTAssertTrue(rows.isEmpty)
    }

    // 8. absorbRealtimePush inserts row into cache; state → .loaded.
    func testAbsorbRealtimePush_InsertsRow() throws {
        let reader = CrossPostLogReader(supabase: makeClient())
        let row = try makeRow(messageID: "msg-rt")
        reader.absorbRealtimePush(row)

        guard case .loaded(let byID) = reader.state else {
            XCTFail("expected .loaded after absorb, got \(reader.state)"); return
        }
        XCTAssertEqual(byID["msg-rt"]?.count, 1)
        XCTAssertEqual(byID["msg-rt"]?.first?.platform, "slack")
    }

    // 9. absorbRealtimePush replaces existing row for same (platform, externalRef) — no duplicates.
    func testAbsorbRealtimePush_ReplacesExistingByPlatformAndExternalRef() throws {
        let reader = CrossPostLogReader(supabase: makeClient())
        let original = try makeRow(messageID: "msg-dup", errorText: "timeout")
        let updated  = try makeRow(messageID: "msg-dup", errorText: nil)  // same platform + externalRef

        reader.absorbRealtimePush(original)
        reader.absorbRealtimePush(updated)

        let rows = reader.crossPosts(for: "msg-dup")
        XCTAssertEqual(rows.count, 1, "same (platform, externalRef) must be deduplicated")
        XCTAssertNil(rows.first?.errorText, "updated row (errorText=nil) should replace original")
    }

    // 10. invalidate removes entries; state reverts to .idle when cache empty.
    func testInvalidate_RemovesMessageEntries() throws {
        let reader = CrossPostLogReader(supabase: makeClient())
        let row = try makeRow(messageID: "msg-inv")
        reader.absorbRealtimePush(row)
        // State should now be .loaded.
        if case .loaded = reader.state { /* pass */ } else {
            XCTFail("expected .loaded before invalidate"); return
        }

        reader.invalidate(messageID: "msg-inv")
        if case .idle = reader.state { /* pass */ } else {
            XCTFail("expected .idle after invalidating last entry, got \(reader.state)")
        }
        XCTAssertTrue(reader.crossPosts(for: "msg-inv").isEmpty)
    }

    // 11. loadForMessages with fetch failure → state → .error.
    func testLoadForMessages_FetchFailure_SetsErrorState() async {
        // Manual bootstrap expansion so the inner closure can throw (wrapWithBootstrap
        // captures a non-throwing closure type; we must inline the handler here).
        let jwt = makeJWT(); let uid = userID
        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "ref",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        await reader.loadForMessages(["msg-fail"])

        if case .error = reader.state { /* pass */ } else {
            XCTFail("expected .error after network failure, got \(reader.state)")
        }
    }

    // 12. loadForMessages with two platforms for same message → grouped correctly by messageID.
    func testLoadForMessages_MultiplePlatformsPerMessage_GroupedCorrectly() async {
        let msgID = "msg-multi"
        let twoRowsJSON = """
        [
          {
            "message_id": "\(msgID)",
            "platform": "slack",
            "external_ref": "#leaf-architecture",
            "external_url": "https://slack.com/archives/C12345/p1716900000",
            "posted_at_ms": 1716900000000,
            "error_text": null
          },
          {
            "message_id": "\(msgID)",
            "platform": "linear",
            "external_ref": "LEA-42",
            "external_url": "https://linear.app/leaf/issue/LEA-42/title",
            "posted_at_ms": 1716900001000,
            "error_text": null
          }
        ]
        """.data(using: .utf8)!

        MockURLProtocol.handler = wrapWithBootstrap { _, _ in
            return (HTTPURLResponse(url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    twoRowsJSON)
        }
        let reader = CrossPostLogReader(supabase: makeClient())
        await reader.loadForMessages([msgID])

        let rows = reader.crossPosts(for: msgID)
        XCTAssertEqual(rows.count, 2, "both platforms must be present for the same messageID")
        XCTAssertTrue(rows.contains { $0.platform == "slack" })
        XCTAssertTrue(rows.contains { $0.platform == "linear" })
    }
}
