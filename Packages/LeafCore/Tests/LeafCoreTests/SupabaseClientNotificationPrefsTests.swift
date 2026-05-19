// Track 5 / S8 / T9 — SupabaseClient.upsertNotificationPref wire coverage.
//
// Mirrors `SupabaseClientTeamEventsTests` shape: anonymous bootstrap →
// register_pubkey → token refresh JWT carries `pubkey` claim → endpoint
// hit. RLS WITH CHECK pubkey = auth.jwt() ->> 'pubkey' enforced
// server-side; client tests verify the body fields + headers + status code
// handling.

import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientNotificationPrefsTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey = String(repeating: "42", count: 32)
    private let userID = "00000000-0000-0000-0000-000000000fff"

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    // MARK: - Helpers (mirror SupabaseClientTeamEventsTests)

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
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    private func wrapWithBootstrap(_ handler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
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
                return handler(request, body)
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

    // MARK: - upsertNotificationPref

    func testUpsertNotificationPref_201_Success() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTAssertEqual(request.url?.path, "/rest/v1/notification_prefs")
            XCTAssertEqual(request.httpMethod, "POST")
            // postgrestUpsertHeaders sets merge-duplicates + return=minimal
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""
            XCTAssertTrue(prefer.contains("resolution=merge-duplicates"), "expected merge-duplicates; got \(prefer)")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.upsertNotificationPref(prefKind: "task", enabled: false)
    }

    func testUpsertNotificationPref_204_Success() async throws {
        // PostgREST merge-duplicates UPSERT often returns 204 No Content with
        // Prefer: return=minimal. Both 200/201/204 must be treated as success.
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.upsertNotificationPref(prefKind: "ping", enabled: true)
    }

    func testUpsertNotificationPref_403_ThrowsForbidden() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"message":"row-level security policy violated"}"#.utf8))
        }
        let client = makeClient()
        do {
            try await client.upsertNotificationPref(prefKind: "task", enabled: false)
            XCTFail("expected throw")
        } catch SupabaseError.forbidden {
            // pass
        }
    }

    func testUpsertNotificationPref_BodyContainsPubkeyAndPrefFields() async throws {
        let captured = SyncBox<Data?>(nil)
        MockURLProtocol.handler = wrapWithBootstrap { [captured] request, body in
            if request.url?.path == "/rest/v1/notification_prefs" {
                captured.set(body)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.upsertNotificationPref(prefKind: "blocker", enabled: false)
        let body = try XCTUnwrap(captured.get())
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        XCTAssertEqual(json["pubkey"] as? String, pubkey, "pubkey should match JWT claim")
        XCTAssertEqual(json["pref_kind"] as? String, "blocker")
        XCTAssertEqual(json["enabled"] as? Bool, false)
        XCTAssertNotNil(json["updated_at_ms"] as? Int64 ?? json["updated_at_ms"].flatMap { $0 as? Int }, "updated_at_ms expected")
    }
}

// SyncBox lives next to SupabaseClientTeamEventsTests; redeclare here to keep
// test file self-contained without cross-file coupling.
private final class SyncBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
