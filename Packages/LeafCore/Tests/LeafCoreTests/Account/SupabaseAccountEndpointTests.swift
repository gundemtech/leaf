import XCTest

@testable import LeafCore

final class SupabaseAccountEndpointTests: XCTestCase {
  private let base = URL(string: "https://proj.supabase.co")!

  func testUserInfoURL() {
    XCTAssertEqual(
      SupabaseEndpoint.userInfo(baseURL: base).absoluteString,
      "https://proj.supabase.co/auth/v1/user")
  }

  func testDeleteSelfAccountRPCURL() {
    XCTAssertEqual(
      SupabaseEndpoint.rpcDeleteSelfAccount(baseURL: base).absoluteString,
      "https://proj.supabase.co/rest/v1/rpc/delete_self_account")
  }
}
