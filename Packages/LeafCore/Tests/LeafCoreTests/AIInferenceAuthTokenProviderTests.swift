import XCTest

@testable import LeafCore

final class AIInferenceAuthTokenProviderTests: XCTestCase {
  struct FakeProvider: AIInferenceAuthTokenProvider {
    let token: String
    func currentAccessToken() async throws -> String { token }
  }

  func testSeamYieldsToken() async throws {
    let provider: any AIInferenceAuthTokenProvider = FakeProvider(token: "tok-123")
    let token = try await provider.currentAccessToken()
    XCTAssertEqual(token, "tok-123")
  }

  func testSeamPropagatesThrow() async {
    struct ThrowingProvider: AIInferenceAuthTokenProvider {
      struct NoSession: Error {}
      func currentAccessToken() async throws -> String { throw NoSession() }
    }
    do {
      _ = try await ThrowingProvider().currentAccessToken()
      XCTFail("expected throw")
    } catch is ThrowingProvider.NoSession {
      // expected
    } catch {
      XCTFail("unexpected \(error)")
    }
  }
}
