import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientSignOutTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-signout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }
  override func tearDown() async throws {
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
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

  func testSignOut_clearsInMemoryState_andPersistedFile() async throws {
    let store = SupabaseSessionStore(at: tempDir)
    try store.write(PersistedSession(refreshToken: "rt", userID: "u", savedAtMs: 1))
    XCTAssertNotNil(try store.read(), "precondition: persisted file exists")

    MockURLProtocol.handler = { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let out = """
        { "access_token": "tok", "refresh_token": "ref",
          "user": { "id": "00000000-0000-0000-0000-0000000000e5" },
          "expires_at": 9999999999 }
        """.data(using: .utf8)!
      return (resp, out)
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: fixedIdentity(), sessionStore: store)
    _ = try await client.signInWithPassword(email: "a@b.co", password: "pw", captchaToken: "c")
    let before = await client.currentSession()
    XCTAssertNotNil(before)

    await client.signOut()

    let after = await client.currentSession()
    XCTAssertNil(after, "in-memory session must be cleared")
    XCTAssertNil(try store.read(), "persisted session file must be deleted")
  }
}
