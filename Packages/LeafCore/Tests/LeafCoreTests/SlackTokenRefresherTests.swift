// Phase 4.4 B3 — SlackTokenRefresher тесты.
// Mock URLSession через URLProtocol + ephemeral session — паттерн из
// `LeafCorePrivateTests.MockURLProtocol`, но локальная копия (test target
// `LeafCoreTests` не может линковаться с private test target).

import Foundation
import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

private final class SlackMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Self.drainBody(from: request)
        do {
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drainBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class SlackTokenRefresherTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-refresher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        // Чистим cross-test state — flag и handler.
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .removeObject(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
        SlackMockURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        SlackMockURLProtocol.handler = nil
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .removeObject(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeDatabase() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeRefresher(database: Database, earlyRefreshSeconds: TimeInterval = 300) -> SlackTokenRefresher {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SlackMockURLProtocol.self]
        return SlackTokenRefresher(
            database: database,
            clientID: "test-client-id",
            earlyRefreshSeconds: earlyRefreshSeconds,
            urlSession: URLSession(configuration: cfg)
        )
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: SlackOAuthEndpoints.token,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func upsertConnected(
        db: Database,
        accessToken: String = "xoxe.xoxp-old",
        refreshToken: String? = "xoxe-1-old",
        expiresAt: Date?,
        connectedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws {
        let record = IntegrationRecord(
            provider: .slack,
            workspaceID: "T123:U456",
            workspaceName: "Acme",
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scope: "users:read,users.profile:read,search:read",
            connectedAt: connectedAt,
            updatedAt: connectedAt
        )
        try db.upsertIntegration(record)
    }

    // MARK: - refreshIfNeeded — short-circuit cases

    /// Token живёт ещё долго (>5 min до expiry) → возврат текущей записи без HTTP.
    func testRefreshIfNeededWhenNotExpired_ReturnsExisting() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, expiresAt: now.addingTimeInterval(3600))  // +1h
        SlackMockURLProtocol.handler = { _, _ in
            XCTFail("Refresh should NOT hit network when token has plenty of life")
            return (self.httpResponse(status: 500), Data())
        }
        let refresher = makeRefresher(database: db)

        let result = try await refresher.refreshIfNeeded(now: now)

        XCTAssertEqual(result.accessToken, "xoxe.xoxp-old")
        XCTAssertEqual(result.refreshToken, "xoxe-1-old")
    }

    /// expiresAt=nil (rotation OFF / long-lived xoxp-) → возврат текущей записи без HTTP.
    func testRefreshIfNeededWhenExpiresAtNil_ReturnsExisting() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, expiresAt: nil)
        SlackMockURLProtocol.handler = { _, _ in
            XCTFail("Refresh should NOT hit network for long-lived (rotation OFF) tokens")
            return (self.httpResponse(status: 500), Data())
        }
        let refresher = makeRefresher(database: db)

        let result = try await refresher.refreshIfNeeded(now: now)

        XCTAssertNil(result.expiresAt)
        XCTAssertEqual(result.accessToken, "xoxe.xoxp-old")
    }

    // MARK: - forceRefresh — happy path

    /// Slack 200 + ok=true + новые top-level access/refresh/expires_in →
    /// upsert IntegrationRecord, возврат обновлённого row.
    func testForceRefreshHappy_StoresNewToken() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, expiresAt: now.addingTimeInterval(60))  // expires soon

        let payload: [String: Any] = [
            "ok": true,
            "access_token": "xoxe.xoxp-NEW",
            "refresh_token": "xoxe-1-NEW",
            "token_type": "user",
            "expires_in": 43200,
            "scope": "users:read,users.profile:read,search:read",
            "team": ["id": "T123", "name": "Acme"],
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)

        var capturedBody: Data?
        var capturedURL: URL?
        SlackMockURLProtocol.handler = { req, body in
            capturedURL = req.url
            capturedBody = body
            return (self.httpResponse(status: 200), json)
        }
        let refresher = makeRefresher(database: db)

        let result = try await refresher.refreshIfNeeded(now: now)

        // Endpoint и form-encoded body содержат всё нужное.
        XCTAssertEqual(capturedURL, SlackOAuthEndpoints.token)
        let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("grant_type=refresh_token"))
        XCTAssertTrue(bodyString.contains("client_id=test-client-id"))
        XCTAssertTrue(bodyString.contains("refresh_token=xoxe-1-old"))

        // Новый record.
        XCTAssertEqual(result.accessToken, "xoxe.xoxp-NEW")
        XCTAssertEqual(result.refreshToken, "xoxe-1-NEW")
        XCTAssertEqual(
            result.expiresAt?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(43200).timeIntervalSince1970,
            accuracy: 0.001
        )
        // workspaceID/connectedAt сохраняются.
        XCTAssertEqual(result.workspaceID, "T123:U456")
        XCTAssertEqual(result.connectedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        // DB действительно обновлена.
        let stored = try db.readIntegration(provider: .slack)
        XCTAssertEqual(stored?.accessToken, "xoxe.xoxp-NEW")
        XCTAssertEqual(stored?.refreshToken, "xoxe-1-NEW")
    }

    // MARK: - forceRefresh — invalid_grant terminal

    /// ok=false + error=invalid_grant → deleteIntegration + UserDefaults flag +
    /// throws .refreshDenied.
    func testForceRefreshOn_invalid_grant_DeletesIntegrationAndSetsFlag() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, expiresAt: now.addingTimeInterval(60))

        let payload: [String: Any] = ["ok": false, "error": "invalid_grant"]
        let json = try JSONSerialization.data(withJSONObject: payload)
        SlackMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 200), json)
        }
        let refresher = makeRefresher(database: db)

        do {
            _ = try await refresher.refreshIfNeeded(now: now)
            XCTFail("Expected refreshDenied error")
        } catch let SlackTokenRefresherError.refreshDenied(code) {
            XCTAssertEqual(code, "invalid_grant")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Row удалён.
        XCTAssertNil(try db.readIntegration(provider: .slack))
        // Flag установлен.
        let flag = UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .bool(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
        XCTAssertEqual(flag, true)
    }

    // MARK: - forceRefresh — transient error

    /// ok=false + non-terminal error (e.g. internal_error) → throws .network,
    /// row остаётся, flag НЕ ставится (юзер увидит retry на следующем tick'е).
    func testForceRefreshOnTransientError_KeepsIntegration() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, expiresAt: now.addingTimeInterval(60))

        let payload: [String: Any] = ["ok": false, "error": "internal_error"]
        let json = try JSONSerialization.data(withJSONObject: payload)
        SlackMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 200), json)
        }
        let refresher = makeRefresher(database: db)

        do {
            _ = try await refresher.refreshIfNeeded(now: now)
            XCTFail("Expected network error")
        } catch SlackTokenRefresherError.network {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Row жив — не было permanent denial.
        XCTAssertNotNil(try db.readIntegration(provider: .slack))
        let flag =
            UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .bool(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey) ?? false
        XCTAssertFalse(flag)
    }

    // MARK: - forceRefresh — missing refresh token

    func testForceRefreshWithoutRefreshToken_Throws() async throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try upsertConnected(db: db, refreshToken: nil, expiresAt: now.addingTimeInterval(60))
        let refresher = makeRefresher(database: db)

        do {
            _ = try await refresher.forceRefresh(now: now)
            XCTFail("Expected missingRefreshToken error")
        } catch SlackTokenRefresherError.missingRefreshToken {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - notConnected

    func testRefreshIfNeededWithoutIntegration_Throws() async throws {
        let db = try makeDatabase()
        let refresher = makeRefresher(database: db)
        do {
            _ = try await refresher.refreshIfNeeded(now: Date())
            XCTFail("Expected notConnected error")
        } catch SlackTokenRefresherError.notConnected {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
// swiftlint:enable force_unwrapping
