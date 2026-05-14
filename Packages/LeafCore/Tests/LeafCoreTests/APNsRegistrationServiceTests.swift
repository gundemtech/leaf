// Phase Track-5 S4 — APNsRegistrationService coverage.
// C5 fix from Stage 6 review.

import XCTest
import CryptoKit
@testable import LeafCore

final class APNsRegistrationServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!
    private let deviceID = "test-device-1"
    private let pubkey = String(repeating: "a", count: 64)
    private let userID = "00000000-0000-0000-0000-000000000fff"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-apns-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    override func tearDown() async throws {
        db = nil
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeJWT(pubkey: String) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    private func makeSupabase() -> SupabaseClient {
        SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
    }

    private func wrapWithBootstrap(
        _ remaining: @escaping @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)
    ) -> @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data) {
        let jwt = makeJWT(pubkey: pubkey)
        let uid = userID
        return { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "t", "refresh_token": "r",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.utf8))
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "r2",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.utf8))
            default:
                return try remaining(request, body)
            }
        }
    }

    func testRecordToken_UpsertsLocalAndMarksServerSynced() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            guard request.url?.path == "/rest/v1/apns_tokens" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        try await svc.recordToken("apns-token-1", environment: "development")

        let local = try db.readSQL { try APNsTokenLocalStore.read(deviceID: deviceID, in: $0) }
        XCTAssertEqual(local?.apnsToken, "apns-token-1")
        XCTAssertEqual(local?.environment, "development")
        XCTAssertNotNil(local?.serverSyncedAtMs, "server sync should be marked after successful Supabase POST")
    }

    func testRecordToken_SupabaseFailureLeavesUnsynced() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            guard request.url?.path == "/rest/v1/apns_tokens" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        do {
            try await svc.recordToken("apns-token-1", environment: "production")
            XCTFail("expected throw on Supabase 500")
        } catch let err as LeafError {
            if case .apnsRegistrationFailed = err {
                // pass
            } else {
                XCTFail("expected .apnsRegistrationFailed, got \(err)")
            }
        }

        // Local row exists with server_synced_at_ms IS NULL — retry candidate.
        let local = try db.readSQL { try APNsTokenLocalStore.read(deviceID: deviceID, in: $0) }
        XCTAssertNotNil(local)
        XCTAssertNil(local?.serverSyncedAtMs)
    }

    func testRetrySync_NoLocalRow_NoOp() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        let result = try await svc.retrySyncIfNeeded()
        XCTAssertFalse(result, "no local row → no-op")
    }

    func testRetrySync_AlreadySynced_NoOp() async throws {
        // Seed a row already synced.
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: deviceID, apnsToken: "tok", environment: "production",
                registeredAtMs: 1_000, in: rawDB
            )
            try APNsTokenLocalStore.markServerSynced(deviceID: deviceID, atMs: 2_000, in: rawDB)
        }

        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTFail("should NOT POST when already synced")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        let result = try await svc.retrySyncIfNeeded()
        XCTAssertFalse(result, "already synced → no-op")
    }

    func testRetrySync_PendingRow_PushesAndMarksSynced() async throws {
        // Seed a pending row (server_synced_at_ms IS NULL).
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: deviceID, apnsToken: "stale-tok", environment: "development",
                registeredAtMs: 1_000, in: rawDB
            )
        }

        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            guard request.url?.path == "/rest/v1/apns_tokens" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        let result = try await svc.retrySyncIfNeeded()
        XCTAssertTrue(result, "pending row → push + mark synced")

        let local = try db.readSQL { try APNsTokenLocalStore.read(deviceID: deviceID, in: $0) }
        XCTAssertNotNil(local?.serverSyncedAtMs)
    }

    func testRecordToken_RotatesAPNsToken_ResetsSyncedMarker() async throws {
        // First registration — succeeds.
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }
        let svc = APNsRegistrationService(database: db, supabase: makeSupabase(), deviceID: deviceID)
        try await svc.recordToken("tok-a", environment: "development")
        let firstSynced = try db.readSQL { try APNsTokenLocalStore.read(deviceID: deviceID, in: $0) }
        XCTAssertNotNil(firstSynced?.serverSyncedAtMs)

        // Token rotation but Supabase fails — should reset synced marker via UPSERT.
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await svc.recordToken("tok-b", environment: "development")
        } catch { /* expected */ }
        let rotated = try db.readSQL { try APNsTokenLocalStore.read(deviceID: deviceID, in: $0) }
        XCTAssertEqual(rotated?.apnsToken, "tok-b")
        XCTAssertNil(rotated?.serverSyncedAtMs, "UPSERT must reset server_synced on token rotation")
    }
}
