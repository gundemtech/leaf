// Track 5 / S3 — InviteAcceptService new single-call API tests.
// Coverage: preview parser; resolve 404 → inviteAlreadyConsumed; OTP required path.
// Full end-to-end crypto round-trip (admin generate → invitee accept) deferred to
// real ProdInviteBlobCodec coverage in LeafCorePrivateTests retrofit (Track 6 cleanup).

import XCTest
import CryptoKit
@testable import LeafCore

final class InviteAcceptServiceTrackFiveTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-accept-t5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        MockURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    private func makeJWT(pubkey: String) -> String {
        let payload = #"{"pubkey":"\#(pubkey)","sub":"00000000-0000-0000-0000-0000000000ee"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "eyJ.\(b64url(payload)).sig"
    }

    /// Track 5 §12 preview — URL parses, returns workspace name + admin pubkey from query params.
    func testPreview_validURL_returnsURLPreview() {
        let token = UUID().base64URLString
        let adminHex = String(repeating: "ad", count: 32)
        let url = InviteURL.compose(
            token: token,
            workspaceName: "TestRoom",
            adminPubkeyHex: adminHex,
            otp: nil
        ).url
        switch InviteAcceptService.preview(url: url) {
        case .success(let preview):
            XCTAssertEqual(preview.workspaceName, "TestRoom")
            XCTAssertEqual(preview.adminPubkeyHex, adminHex)
            XCTAssertEqual(preview.token, token)
            XCTAssertFalse(preview.hasFragmentOTP)
        case .failure:
            XCTFail("expected preview success")
        }
    }

    func testPreview_withFragmentOTP_setsHasFragmentOTP() {
        let url = InviteURL.compose(
            token: UUID().base64URLString,
            workspaceName: "X",
            adminPubkeyHex: String(repeating: "ad", count: 32),
            otp: "123456"
        ).url
        guard case .success(let preview) = InviteAcceptService.preview(url: url) else {
            XCTFail("expected success"); return
        }
        XCTAssertTrue(preview.hasFragmentOTP)
    }

    func testPreview_malformedURL_returnsMalformed() {
        let url = URL(string: "https://wrong/scheme")!
        guard case .failure(.malformed) = InviteAcceptService.preview(url: url) else {
            XCTFail("expected .malformed"); return
        }
    }

    /// resolve returns 404 → InviteAcceptService throws .inviteAlreadyConsumed.
    func testAcceptInvite_resolve404_throwsAlreadyConsumed() async throws {
        let inviteeBytes = Data(repeating: 0xEE, count: 32)
        let inviteeHex = (try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: inviteeBytes))
            .publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "t", "refresh_token": "r",
                  "user": { "id": "00000000-0000-0000-0000-0000000000ee" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{ "ok": true }"#.data(using: .utf8)!)
            case "/auth/v1/token":
                let jwt = self.makeJWT(pubkey: inviteeHex)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "r",
                          "user": { "id": "00000000-0000-0000-0000-0000000000ee" },
                          "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/invite_resolve":
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        #"{ "error": "not_resolvable" }"#.data(using: .utf8)!)
            default:
                XCTFail("unexpected path \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: inviteeBytes) }
        )
        let service = InviteAcceptService(
            database: db, supabase: supabase,
            inviteKDF: TestInviteKDF(), inviteBlobCodec: TestInviteBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: inviteeBytes) }
        )
        let url = InviteURL.compose(
            token: UUID().base64URLString,
            workspaceName: "X",
            adminPubkeyHex: String(repeating: "ad", count: 32),
            otp: nil
        ).url
        do {
            _ = try await service.acceptInvite(url: url, displayName: "Bob", otp: nil as String?)
            XCTFail("expected throw")
        } catch LeafError.inviteAlreadyConsumed {
            // expected
        } catch {
            XCTFail("expected .inviteAlreadyConsumed got \(error)")
        }
    }

    func testAcceptInvite_emptyDisplayName_throwsInvalidPayload() async throws {
        let supabase = SupabaseClient(
            baseURL: URL(string: "https://stub")!, anonKey: "k",
            urlSession: makeSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)) }
        )
        let service = InviteAcceptService(
            database: db, supabase: supabase,
            inviteKDF: TestInviteKDF(), inviteBlobCodec: TestInviteBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
        let url = InviteURL.compose(
            token: UUID().base64URLString,
            workspaceName: "X",
            adminPubkeyHex: String(repeating: "ad", count: 32),
            otp: nil
        ).url
        do {
            _ = try await service.acceptInvite(url: url, displayName: "", otp: nil)
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // expected
        }
    }

    func testAcceptInvite_malformedURL_throwsURLMalformed() async throws {
        let supabase = SupabaseClient(
            baseURL: URL(string: "https://stub")!, anonKey: "k",
            urlSession: makeSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)) }
        )
        let service = InviteAcceptService(
            database: db, supabase: supabase,
            inviteKDF: TestInviteKDF(), inviteBlobCodec: TestInviteBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
        let url = URL(string: "https://wrong/scheme")!
        do {
            _ = try await service.acceptInvite(url: url, displayName: "Bob", otp: nil as String?)
            XCTFail("expected throw")
        } catch LeafError.inviteURLMalformed {
            // expected
        }
    }
}

// MARK: - Test doubles

private struct TestInviteKDF: InviteKDF {
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0xCC, count: 32))
    }
    func hashOTPForServerStorage(otp: String) -> Data {
        Data(repeating: 0xDD, count: 32)
    }
}

private struct TestInviteBlobCodec: InviteBlobCodec {
    func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws -> InviteBlob {
        var bytes = Data([1])
        bytes.append(adminPubkey)
        if let body = try? JSONEncoder().encode(plaintext) { bytes.append(body) }
        return InviteBlob(bytes: bytes)
    }
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        let bodyStart = 1 + 32
        guard blob.bytes.count > bodyStart else { throw LeafError.inviteBlobMalformed }
        let body = blob.bytes.subdata(in: bodyStart..<blob.bytes.count)
        return try JSONDecoder().decode(InvitePlaintext.self, from: body)
    }
}
