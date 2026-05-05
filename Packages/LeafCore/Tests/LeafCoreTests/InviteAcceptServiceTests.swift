// Phase 5.2.E — InviteAcceptService invitee-orchestrator tests.
// fetchInvite: 3 cases via real RelayClient + URLProtocol stub (mirror
// InviteServiceTests harness). acceptInvite: full crypto chain in C3.

import XCTest
import CryptoKit
import Foundation
@testable import LeafCore

private final class AcceptServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lastRequest = request
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubInviteKDF: InviteKDF, @unchecked Sendable {
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0xAB, count: 32))
    }
}

private final class StubInviteBlobCodec: InviteBlobCodec, @unchecked Sendable {
    func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws -> InviteBlob {
        fatalError("unused in accept path")
    }
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        fatalError("acceptInvite tests in C3 inject specific decode behavior")
    }
}

final class InviteAcceptServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-accept-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        AcceptServiceMockURLProtocol.handler = nil
        AcceptServiceMockURLProtocol.lastRequest = nil
    }

    override func tearDown() async throws {
        AcceptServiceMockURLProtocol.handler = nil
        AcceptServiceMockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRelayClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AcceptServiceMockURLProtocol.self]
        return RelayClient(baseURL: URL(string: "https://stub.example")!,
                           urlSession: URLSession(configuration: config))
    }

    private func makeService() -> InviteAcceptService {
        InviteAcceptService(
            database: db,
            relayClient: makeRelayClient(),
            inviteKDF: StubInviteKDF(),
            inviteBlobCodec: StubInviteBlobCodec(),
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            identity: { Curve25519.KeyAgreement.PrivateKey() },
            generateMemberID: { "fixed-member-id" }
        )
    }

    // MARK: - fetchInvite

    func testFetchInvite_Success_ReturnsBlobBytes() async throws {
        let blobBytes = Data([0x02] + (0..<140).map { _ in UInt8.random(in: 0...255) })
        let b64url = blobBytes.base64URLNoPad
        AcceptServiceMockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/invite/tok_abc123"))
            let body = """
            {"blob":"\(b64url)","expires_at_ms":1700086400000}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }

        let svc = makeService()
        let blob = try await svc.fetchInvite(token: "tok_abc123")
        XCTAssertEqual(blob.bytes, blobBytes)
    }

    func testFetchInvite_404_MapsToInviteNotFound() async throws {
        AcceptServiceMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil,
                                       headerFields: nil)!
            return (resp, nil)
        }
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "tok_missing")
            XCTFail("expected inviteNotFound")
        } catch LeafError.inviteNotFound {
            // ok
        }
    }

    func testFetchInvite_TransportFailure_MapsToRelayUnreachable() async throws {
        AcceptServiceMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "tok_offline")
            XCTFail("expected relayUnreachable")
        } catch LeafError.relayUnreachable(let reason) {
            XCTAssertEqual(reason, "transport")
        }
    }

    func testFetchInvite_EmptyToken_RejectedAsInvalidPayload() async throws {
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "   ")
            XCTFail("expected invalidPayload")
        } catch LeafError.invalidPayload {
            // ok
        }
    }
}
