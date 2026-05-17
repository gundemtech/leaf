// Phase 5.2.D — RelayClient HTTP wire tests.
// URLProtocol stub harness mirror'ит SlackTokenRefresherTests pattern: file-local
// subclass, ephemeral session per call, setUp/tearDown reset static handler.

import Foundation
import XCTest

@testable import LeafCore

private final class RelayMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let err = Self.networkError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Self.drainBody(from: request)
        Self.lastRequest = request
        Self.lastBody = body
        do {
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
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

final class RelayClientTests: XCTestCase {

    private let stubBase = URL(string: "https://stub.example")!

    override func setUp() async throws {
        RelayMockURLProtocol.handler = nil
        RelayMockURLProtocol.networkError = nil
        RelayMockURLProtocol.lastRequest = nil
        RelayMockURLProtocol.lastBody = nil
    }

    override func tearDown() async throws {
        RelayMockURLProtocol.handler = nil
        RelayMockURLProtocol.networkError = nil
        RelayMockURLProtocol.lastRequest = nil
        RelayMockURLProtocol.lastBody = nil
    }

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient() -> RelayClient {
        RelayClient(baseURL: stubBase, urlSession: makeStubSession())
    }

    private func httpResponse(
        _ status: Int, url: URL? = nil, contentType: String = "application/json"
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? stubBase, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!
    }

    private let validPubkeyHex = String(repeating: "a", count: 64)
    private let sampleBlob = Data([0x02] + (0..<60).map { UInt8($0) })

    // MARK: - postInvite

    func testPostInvite_201_ReturnsToken() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"token":"tok_abc123","expires_at_ms":1700000000000}"#.data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), body)
        }
        let client = makeClient()
        let token = try await client.postInvite(
            memberPubkeyHex: validPubkeyHex,
            blob: sampleBlob,
            expiresAtMs: 1_700_000_000_000)
        XCTAssertEqual(token.value, "tok_abc123")
        XCTAssertEqual(token.expiresAtMs, 1_700_000_000_000)
    }

    func testPostInvite_SendsCorrectJSONBody() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"token":"t","expires_at_ms":1}"#.data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), body)
        }
        let client = makeClient()
        let blob = Data([0x01, 0x02, 0x03])  // base64url no-pad → "AQID"
        // Caller (InviteService) is responsible for lowercasing; RelayClient passes through.
        let lowercasedHex = "aabbccdd" + String(repeating: "0", count: 56)
        _ = try await client.postInvite(
            memberPubkeyHex: lowercasedHex,
            blob: blob,
            expiresAtMs: 9_999_999_999)
        let req = try XCTUnwrap(RelayMockURLProtocol.lastRequest)
        let body = try XCTUnwrap(RelayMockURLProtocol.lastBody)

        XCTAssertEqual(req.url?.path, "/v1/invite")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["member_pubkey_hex"] as? String, lowercasedHex)
        XCTAssertEqual(json["blob"] as? String, "AQID")
        let expires = (json["expires_at_ms"] as? NSNumber)?.int64Value
        XCTAssertEqual(expires, 9_999_999_999)
    }

    func testPostInvite_400_ThrowsInviteRequestRejected_BadInput() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(400, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postInvite(
                memberPubkeyHex: validPubkeyHex,
                blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.inviteRequestRejected(reason) {
            XCTAssertEqual(reason, "bad-input")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostInvite_413_ThrowsInviteRequestRejected_Size() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(413, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postInvite(
                memberPubkeyHex: validPubkeyHex,
                blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.inviteRequestRejected(reason) {
            XCTAssertEqual(reason, "size")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostInvite_500_ThrowsRelayUnreachable_ServerError() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(500, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postInvite(
                memberPubkeyHex: validPubkeyHex,
                blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "server-error")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostInvite_NetworkError_ThrowsRelayUnreachable_Transport() async {
        RelayMockURLProtocol.networkError = URLError(.notConnectedToInternet)
        let client = makeClient()
        do {
            _ = try await client.postInvite(
                memberPubkeyHex: validPubkeyHex,
                blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "transport")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostInvite_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse() async {
        RelayMockURLProtocol.handler = { req, _ in
            let bogus = "not-json".data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), bogus)
        }
        let client = makeClient()
        do {
            _ = try await client.postInvite(
                memberPubkeyHex: validPubkeyHex,
                blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "malformed-response")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - getInvite

    func testGetInvite_200_ReturnsBlobAndExpiry() async throws {
        // payload "blob" as base64url no-pad of [0xDE,0xAD,0xBE,0xEF] = "3q2-7w"
        // (standard b64 "3q2+7w==" → url-safe no-pad)
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"blob":"3q2-7w","expires_at_ms":1700000000000}"#
                .data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), body)
        }
        let client = makeClient()
        let fetched = try await client.getInvite(token: "tok_abc")
        XCTAssertEqual(Array(fetched.blob), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(fetched.expiresAtMs, 1_700_000_000_000)

        let req = try XCTUnwrap(RelayMockURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/v1/invite/tok_abc")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    func testGetInvite_404_ThrowsInviteNotFound() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(404, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.getInvite(token: "missing")
            XCTFail("expected throw")
        } catch LeafError.inviteNotFound {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - deleteInvite

    func testDeleteInvite_204_Success() async throws {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(204, url: req.url), nil) }
        let client = makeClient()
        try await client.deleteInvite(token: "tok_xyz")
        let req = try XCTUnwrap(RelayMockURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/v1/invite/tok_xyz")
        XCTAssertEqual(req.httpMethod, "DELETE")
    }

    func testDeleteInvite_NetworkError_ThrowsRelayUnreachable_Transport() async {
        RelayMockURLProtocol.networkError = URLError(.timedOut)
        let client = makeClient()
        do {
            try await client.deleteInvite(token: "tok_xyz")
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "transport")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Defaults

    func testInit_DefaultBaseURL_OauthGundemTech() async {
        let client = RelayClient()
        let baseURL = await client.baseURL
        XCTAssertEqual(baseURL.absoluteString, "https://oauth.gundem.tech")
    }
}
