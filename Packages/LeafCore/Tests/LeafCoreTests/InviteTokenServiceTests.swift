// M027 — InviteTokenService coverage (admin generate/list/delete + refresh).
//
// Uses real LeafCore.Database (in-memory tempdir SQLCipher) + real
// SupabaseClient with MockURLProtocol-injected URLSession (no real network).

import XCTest
import CryptoKit
@testable import LeafCore

final class InviteTokenServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!
    private let workspaceID = "11111111-1111-1111-1111-111111111111"
    private let adminPubkey = String(repeating: "a", count: 64)
    private let anonKey = "test-anon"
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let fixedNow = Date(timeIntervalSince1970: 1_716_220_800)  // 2026-05-20T12:00:00Z

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-invite-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
        // Seed workspace row (local SQLCipher schema).
        try db.writeSQL { raw in
            try raw.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName)
                    (\(Schema.Workspaces.id), \(Schema.Workspaces.name),
                     \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID))
                VALUES (?, 'TestRoom', 1700000000000, 'm1')
                """, arguments: [workspaceID])
        }
    }

    override func tearDown() async throws {
        db = nil
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - URL session + auth bootstrap

    private func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeJWT(pubkey: String) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"00000000-0000-0000-0000-000000000222"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).fake-sig"
    }

    private func bootstrap(
        invitePostHandler: @escaping (URLRequest, Data) -> (HTTPURLResponse, Data),
        inviteGetHandler:  ((URLRequest) -> (HTTPURLResponse, Data))? = nil,
        invitePatchHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil
    ) {
        let refreshedJWT = makeJWT(pubkey: adminPubkey)
        MockURLProtocol.handler = { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "tok-1", "refresh_token": "ref-1",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/functions/v1/register_pubkey":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, #"{ "ok": true }"#.data(using: .utf8)!)
            case "/auth/v1/token":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "\(refreshedJWT)", "refresh_token": "ref-2",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/rest/v1/invite_tokens":
                switch request.httpMethod {
                case "POST":
                    return invitePostHandler(request, body)
                case "GET":
                    return inviteGetHandler?(request) ?? (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        "[]".data(using: .utf8)!
                    )
                case "PATCH":
                    return invitePatchHandler?(request, body) ?? (
                        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil,
                                         headerFields: ["Content-Range": "0-0/1"])!,
                        Data()
                    )
                default:
                    XCTFail("unexpected method \(request.httpMethod ?? "?") on \(path)")
                    return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
                }
            default:
                XCTFail("unexpected path \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
    }

    private func makeSupabase() -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL, anonKey: anonKey, urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32)) }
        )
    }

    private func makeService(supabase: SupabaseClient? = nil) -> InviteTokenService {
        let capturedNow = fixedNow
        return InviteTokenService(
            database: db, supabase: supabase ?? makeSupabase(),
            workspaceID: workspaceID,
            createdByPubkeyHex: adminPubkey,
            now: { capturedNow }
        )
    }

    /// Server response: echo back input as JSON row (best-effort — accepts any
    /// fields, picks reasonable defaults). Sufficient for service-level coverage.
    private func echoRow(_ code: String, expiresAt: Date?, maxUses: Int?, label: String?) -> String {
        var fields: [String] = []
        fields.append(#""code": "\#(code)""#)
        fields.append(#""workspace_id": "\#(workspaceID)""#)
        fields.append(#""created_by_pubkey": "\#(adminPubkey)""#)
        if let label = label { fields.append(#""label": "\#(label)""#) } else { fields.append(#""label": null"#) }
        fields.append(#""ttl_seconds": 86400"#)
        if let expiresAt = expiresAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            fields.append(#""expires_at": "\#(iso.string(from: expiresAt))""#)
        } else {
            fields.append(#""expires_at": null"#)
        }
        if let maxUses = maxUses { fields.append(#""max_uses": \#(maxUses)"#) } else { fields.append(#""max_uses": null"#) }
        fields.append(#""used_count": 0"#)
        fields.append(#""deleted_at": null"#)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        fields.append(#""created_at": "\#(iso.string(from: fixedNow))""#)
        return "[{ \(fields.joined(separator: ", ")) }]"
    }

    // MARK: - generate

    func testGenerate_CreatesTokenServerSideAndMirrorsLocally() async throws {
        var capturedBody: Data?
        bootstrap(invitePostHandler: { request, body in
            capturedBody = body
            // Extract `code` from request body — server echoes back what was sent.
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: self.fixedNow.addingTimeInterval(86400),
                                         maxUses: nil, label: "Team kickoff")
            return (resp, respBody.data(using: .utf8)!)
        })

        let service = makeService()
        let token = try await service.generate(label: "Team kickoff", ttlSeconds: 86400, singleUse: false)
        XCTAssertTrue(token.code.hasPrefix("LEAF-"))
        XCTAssertEqual(token.code.count, 19)
        XCTAssertEqual(token.label, "Team kickoff")
        XCTAssertNil(token.maxUses)
        XCTAssertNotNil(token.expiresAt)

        // Local mirror reflects server's echoed row.
        let local = try db.fetchInviteToken(code: token.code)
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.label, "Team kickoff")

        // Posted body includes generated code + correct admin pubkey.
        let body = try XCTUnwrap(capturedBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["created_by_pubkey"] as? String, adminPubkey)
        let postedCode = (parsed["code"] as? String) ?? ""
        XCTAssertEqual(postedCode.count, 19)
        XCTAssertEqual(parsed["ttl_seconds"] as? Int, 86400)
    }

    func testGenerate_SingleUseSetsMaxUses1() async throws {
        bootstrap(invitePostHandler: { request, body in
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: self.fixedNow.addingTimeInterval(3600),
                                         maxUses: 1, label: nil)
            return (resp, respBody.data(using: .utf8)!)
        })

        let service = makeService()
        let token = try await service.generate(label: nil, ttlSeconds: 3600, singleUse: true)
        XCTAssertEqual(token.maxUses, 1)
    }

    func testGenerate_TTLZero_NeverExpires() async throws {
        var capturedBody: Data?
        bootstrap(invitePostHandler: { request, body in
            capturedBody = body
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: nil, maxUses: nil, label: nil)
            return (resp, respBody.data(using: .utf8)!)
        })

        let service = makeService()
        let token = try await service.generate(label: nil, ttlSeconds: 0, singleUse: false)
        XCTAssertNil(token.expiresAt)

        // Verify request body omits `expires_at`.
        let body = try XCTUnwrap(capturedBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(parsed["expires_at"])
    }

    func testGenerate_TenActiveTokensThenEleventhRejected() async throws {
        bootstrap(invitePostHandler: { request, body in
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: self.fixedNow.addingTimeInterval(86400),
                                         maxUses: nil, label: nil)
            return (resp, respBody.data(using: .utf8)!)
        })

        let service = makeService()
        for _ in 0..<10 {
            _ = try await service.generate(label: nil, ttlSeconds: 86400, singleUse: false)
        }
        // 11th should fail.
        do {
            _ = try await service.generate(label: nil, ttlSeconds: 86400, singleUse: false)
            XCTFail("expected throw on 11th generate")
        } catch let error as InviteTokenError {
            XCTAssertEqual(error, .maxActiveTokensReached)
        }
    }

    // MARK: - listActive / fetch

    func testListActive_ReturnsLocalMirrorOnly() async throws {
        bootstrap(invitePostHandler: { request, body in
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: self.fixedNow.addingTimeInterval(86400),
                                         maxUses: nil, label: "Active")
            return (resp, respBody.data(using: .utf8)!)
        })

        let service = makeService()
        _ = try await service.generate(label: "Active", ttlSeconds: 86400, singleUse: false)
        _ = try await service.generate(label: "Active2", ttlSeconds: 86400, singleUse: false)
        let active = try service.listActive()
        XCTAssertEqual(active.count, 2)
    }

    // MARK: - delete

    func testDelete_MarksServerAndLocalMirror() async throws {
        var patchCalled = false
        var patchedCode: String?
        bootstrap(invitePostHandler: { request, body in
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (parsed?["code"] as? String) ?? "LEAF-AAAA-BBBB-CCCC"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = self.echoRow(code, expiresAt: self.fixedNow.addingTimeInterval(86400),
                                         maxUses: nil, label: "ToDelete")
            return (resp, respBody.data(using: .utf8)!)
        }, invitePatchHandler: { request, body in
            patchCalled = true
            // Extract code from request URL query string.
            if let url = request.url?.absoluteString,
               let range = url.range(of: "code=eq.") {
                patchedCode = String(url[range.upperBound...])
            }
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Content-Range": "0-0/1"]
            )!
            return (resp, Data())
        })

        let service = makeService()
        let token = try await service.generate(label: "ToDelete", ttlSeconds: 86400, singleUse: false)
        try await service.delete(code: token.code)

        XCTAssertTrue(patchCalled)
        XCTAssertEqual(patchedCode, token.code)

        let local = try db.fetchInviteToken(code: token.code)
        XCTAssertNotNil(local?.deletedAt)
    }
}
