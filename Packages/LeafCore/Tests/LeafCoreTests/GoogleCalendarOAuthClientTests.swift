// Track-6 P4 Task 9 — GoogleCalendarOAuthClient tests.
// Mock URLSession через URLProtocol + ephemeral session — same pattern as
// SlackTokenRefresherTests / RelayClientTests.

import Foundation
import XCTest

@testable import LeafCore

private final class GoogleOAuthMockURLProtocol: URLProtocol {
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

final class GoogleCalendarOAuthClientTests: XCTestCase {

    private func makeClient() -> GoogleCalendarOAuthClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GoogleOAuthMockURLProtocol.self]
        return GoogleCalendarOAuthClient(urlSession: URLSession(configuration: cfg))
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: GoogleCalendarOAuthEndpoints.tokenURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    override func tearDown() async throws {
        GoogleOAuthMockURLProtocol.handler = nil
    }

    // MARK: - exchangeCode

    func testExchangeCodeSucceedsWithCannedResponse() async throws {
        let canned = #"""
            {
              "access_token": "ya29.abc",
              "expires_in": 3920,
              "refresh_token": "1//rt-aaa",
              "scope": "https://www.googleapis.com/auth/calendar.readonly",
              "token_type": "Bearer"
            }
            """#
        GoogleOAuthMockURLProtocol.handler = { req, body in
            XCTAssertEqual(req.url, GoogleCalendarOAuthEndpoints.tokenURL)
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let bodyStr = String(data: body, encoding: .utf8) ?? ""
            XCTAssertTrue(bodyStr.contains("grant_type=authorization_code"), "body=\(bodyStr)")
            XCTAssertTrue(bodyStr.contains("code=abc123"))
            XCTAssertTrue(bodyStr.contains("code_verifier=verifier-xyz"))
            XCTAssertTrue(bodyStr.contains("client_id=test-client"))
            XCTAssertTrue(bodyStr.contains("client_secret=test-secret"))
            return (self.httpResponse(status: 200), canned.data(using: .utf8)!)
        }

        let client = makeClient()
        let resp = try await client.exchangeCode(
            code: "abc123",
            codeVerifier: "verifier-xyz",
            redirectURI: "http://127.0.0.1:54321/callback",
            clientID: "test-client",
            clientSecret: "test-secret"
        )

        XCTAssertEqual(resp.accessToken, "ya29.abc")
        XCTAssertEqual(resp.expiresIn, 3920)
        XCTAssertEqual(resp.refreshToken, "1//rt-aaa")
        XCTAssertEqual(resp.tokenType, "Bearer")
    }

    func testExchangeCodeOn400InvalidGrantThrowsInvalidGrant() async throws {
        let body = #"{"error":"invalid_grant","error_description":"Bad Request"}"#
        GoogleOAuthMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 400), body.data(using: .utf8)!)
        }

        let client = makeClient()
        do {
            _ = try await client.exchangeCode(
                code: "x", codeVerifier: "y", redirectURI: "z",
                clientID: "c", clientSecret: "s"
            )
            XCTFail("Expected invalidGrant")
        } catch let err as GoogleCalendarOAuthError {
            XCTAssertEqual(err, .invalidGrant)
        }
    }

    func testExchangeCodeOn500ThrowsHttp() async throws {
        GoogleOAuthMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 500), Data("oops".utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.exchangeCode(
                code: "x", codeVerifier: "y", redirectURI: "z",
                clientID: "c", clientSecret: "s"
            )
            XCTFail("Expected http(500, _)")
        } catch let GoogleCalendarOAuthError.http(statusCode, _) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - refreshToken

    func testRefreshTokenSuccessWithRotatedRefreshToken() async throws {
        let canned = #"""
            {
              "access_token": "ya29.new",
              "expires_in": 3600,
              "refresh_token": "1//rt-rotated",
              "scope": "https://www.googleapis.com/auth/calendar.readonly",
              "token_type": "Bearer"
            }
            """#
        GoogleOAuthMockURLProtocol.handler = { req, body in
            let bodyStr = String(data: body, encoding: .utf8) ?? ""
            XCTAssertTrue(bodyStr.contains("grant_type=refresh_token"), "body=\(bodyStr)")
            XCTAssertTrue(bodyStr.contains("refresh_token=1//rt-old"))
            // No code_verifier on refresh.
            XCTAssertFalse(bodyStr.contains("code_verifier"))
            XCTAssertEqual(req.url, GoogleCalendarOAuthEndpoints.tokenURL)
            return (self.httpResponse(status: 200), canned.data(using: .utf8)!)
        }

        let client = makeClient()
        let resp = try await client.refreshToken(
            refreshToken: "1//rt-old",
            clientID: "test-client",
            clientSecret: "test-secret"
        )
        XCTAssertEqual(resp.accessToken, "ya29.new")
        XCTAssertEqual(resp.refreshToken, "1//rt-rotated")
    }

    func testRefreshTokenSuccessWithMissingRefreshTokenIsTolerated() async throws {
        // Google's documented behavior — refresh_token field OMITTED on most
        // refresh responses (only rotated occasionally). Caller preserves the
        // old refresh_token; NOT a throw.
        let canned = #"""
            {
              "access_token": "ya29.new",
              "expires_in": 3600,
              "scope": "https://www.googleapis.com/auth/calendar.readonly",
              "token_type": "Bearer"
            }
            """#
        GoogleOAuthMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 200), canned.data(using: .utf8)!)
        }

        let client = makeClient()
        let resp = try await client.refreshToken(
            refreshToken: "1//rt-old",
            clientID: "test-client",
            clientSecret: "test-secret"
        )
        XCTAssertEqual(resp.accessToken, "ya29.new")
        XCTAssertNil(resp.refreshToken)
    }

    func testRefreshTokenOn400InvalidGrantThrowsInvalidGrant() async throws {
        let body = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        GoogleOAuthMockURLProtocol.handler = { _, _ in
            (self.httpResponse(status: 400), body.data(using: .utf8)!)
        }

        let client = makeClient()
        do {
            _ = try await client.refreshToken(
                refreshToken: "1//rt-old",
                clientID: "test-client",
                clientSecret: "test-secret"
            )
            XCTFail("Expected invalidGrant")
        } catch let err as GoogleCalendarOAuthError {
            XCTAssertEqual(err, .invalidGrant)
        }
    }
}
