// Phase 5.3.C — RelayClient rotation methods HTTP wire tests.
// URLProtocol stub harness mirror'ит RelayClientTests pattern (file-local
// subclass duplicate per spec §5.1 — test isolation, no cross-file static state).

import XCTest
import Foundation
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

final class RelayClientRotationTests: XCTestCase {

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

    private func httpResponse(_ status: Int, url: URL? = nil, contentType: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? stubBase, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": contentType])!
    }

    private let validPubkeyHex = String(repeating: "a", count: 64)
    private let sampleBlob = Data([0x03] + (0..<108).map { UInt8($0 % 256) })

    // MARK: - postRotationBlob

    func testPostRotationBlob_201_ReturnsToken() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"rotation_id":"rot_abc123","expires_at_ms":1700000000000}"#.data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), body)
        }
        let client = makeClient()
        let token = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                      blob: sampleBlob,
                                                      expiresAtMs: 1_700_000_000_000)
        XCTAssertEqual(token.value, "rot_abc123")
        XCTAssertEqual(token.expiresAtMs, 1_700_000_000_000)
    }

    func testPostRotationBlob_SendsCorrectJSONBody() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"rotation_id":"r","expires_at_ms":1}"#.data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), body)
        }
        let client = makeClient()
        let blob = Data([0x01, 0x02, 0x03])  // base64url no-pad → "AQID"
        let lowercasedHex = "aabbccdd" + String(repeating: "0", count: 56)
        _ = try await client.postRotationBlob(peerPubkeyHex: lowercasedHex,
                                              blob: blob,
                                              expiresAtMs: 9_999_999_999)
        let req = try XCTUnwrap(RelayMockURLProtocol.lastRequest)
        let body = try XCTUnwrap(RelayMockURLProtocol.lastBody)

        XCTAssertEqual(req.url?.path, "/v1/key-rotation")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["peer_pubkey_hex"] as? String, lowercasedHex)
        XCTAssertEqual(json["blob"] as? String, "AQID")
        let expires = (json["expires_at_ms"] as? NSNumber)?.int64Value
        XCTAssertEqual(expires, 9_999_999_999)
    }

    func testPostRotationBlob_400_ThrowsRotationRequestRejected_BadInput() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(400, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.rotationRequestRejected(reason) {
            XCTAssertEqual(reason, "bad-input")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostRotationBlob_413_ThrowsRotationRequestRejected_Size() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(413, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.rotationRequestRejected(reason) {
            XCTAssertEqual(reason, "size")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostRotationBlob_415_ThrowsRotationRequestRejected_MediaType() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(415, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.rotationRequestRejected(reason) {
            XCTAssertEqual(reason, "media-type")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostRotationBlob_500_ThrowsRelayUnreachable_ServerError() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(500, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "server-error")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostRotationBlob_NetworkError_ThrowsRelayUnreachable_Transport() async {
        RelayMockURLProtocol.networkError = URLError(.notConnectedToInternet)
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "transport")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPostRotationBlob_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse() async {
        RelayMockURLProtocol.handler = { req, _ in
            let bogus = "not-json".data(using: .utf8)!
            return (self.httpResponse(201, url: req.url), bogus)
        }
        let client = makeClient()
        do {
            _ = try await client.postRotationBlob(peerPubkeyHex: validPubkeyHex,
                                                  blob: sampleBlob, expiresAtMs: 1)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "malformed-response")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - fetchPendingRotations

    func testFetchPendingRotations_200_EmptyArray_ReturnsEmpty() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"rotations":[]}"#.data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), body)
        }
        let client = makeClient()
        let result = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
        XCTAssertEqual(result, [])
    }

    func testFetchPendingRotations_200_PopulatedArray_ReturnsItems() async throws {
        // Two rotations; "3q2-7w" decodes to [0xDE,0xAD,0xBE,0xEF].
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"""
            {"rotations":[
                {"rotation_id":"rot_one","blob":"3q2-7w","expires_at_ms":1700000000000},
                {"rotation_id":"rot_two","blob":"AQID","expires_at_ms":1700000999999}
            ]}
            """#.data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), body)
        }
        let client = makeClient()
        let result = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].rotationID, "rot_one")
        XCTAssertEqual(Array(result[0].blob), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(result[0].expiresAtMs, 1_700_000_000_000)
        XCTAssertEqual(result[1].rotationID, "rot_two")
        XCTAssertEqual(Array(result[1].blob), [0x01, 0x02, 0x03])
        XCTAssertEqual(result[1].expiresAtMs, 1_700_000_999_999)
    }

    func testFetchPendingRotations_SendsCorrectURLPath() async throws {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"rotations":[]}"#.data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), body)
        }
        let client = makeClient()
        _ = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
        let req = try XCTUnwrap(RelayMockURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/v1/key-rotation/by-peer/\(validPubkeyHex)")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    func testFetchPendingRotations_400_ThrowsRotationRequestRejected_BadInput() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(400, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
            XCTFail("expected throw")
        } catch let LeafError.rotationRequestRejected(reason) {
            XCTAssertEqual(reason, "bad-input")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchPendingRotations_500_ThrowsRelayUnreachable_ServerError() async {
        RelayMockURLProtocol.handler = { req, _ in (self.httpResponse(500, url: req.url), nil) }
        let client = makeClient()
        do {
            _ = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "server-error")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchPendingRotations_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse() async {
        RelayMockURLProtocol.handler = { req, _ in
            let bogus = "not-json".data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), bogus)
        }
        let client = makeClient()
        do {
            _ = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "malformed-response")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchPendingRotations_MissingRotationsKey_ThrowsRelayUnreachable_MalformedResponse() async {
        RelayMockURLProtocol.handler = { req, _ in
            let body = #"{"other":"shape"}"#.data(using: .utf8)!
            return (self.httpResponse(200, url: req.url), body)
        }
        let client = makeClient()
        do {
            _ = try await client.fetchPendingRotations(forPeerPubkeyHex: validPubkeyHex)
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "malformed-response")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
