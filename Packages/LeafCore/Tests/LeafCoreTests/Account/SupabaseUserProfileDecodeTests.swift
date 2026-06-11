import XCTest

@testable import LeafCore

final class SupabaseUserProfileDecodeTests: XCTestCase {
  private func decode(_ json: String) throws -> SupabaseUserProfile {
    try JSONDecoder().decode(SupabaseUserProfile.self, from: Data(json.utf8))
  }

  func testFullOAuthBody() throws {
    let p = try decode(
      """
      { "id": "00000000-0000-0000-0000-0000000000aa",
        "email": "sam@example.com",
        "created_at": "2024-06-10T12:34:56.000Z",
        "app_metadata": { "provider": "google" },
        "user_metadata": { "full_name": "Sam Rivera", "name": "SR" } }
      """)
    XCTAssertEqual(p.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000aa"))
    XCTAssertEqual(p.email, "sam@example.com")
    XCTAssertEqual(p.provider, "google")
    XCTAssertEqual(p.fullName, "Sam Rivera")
    XCTAssertEqual(p.createdAt, "2024-06-10T12:34:56.000Z")
  }

  func testFullNameFallsBackToNameThenUserName() throws {
    let onlyName = try decode(#"{ "user_metadata": { "name": "Just Name" } }"#)
    XCTAssertEqual(onlyName.fullName, "Just Name")
    let onlyUser = try decode(#"{ "user_metadata": { "user_name": "ghhandle" } }"#)
    XCTAssertEqual(onlyUser.fullName, "ghhandle")
  }

  func testMinimalEmailProviderDefaultsNil() throws {
    let p = try decode(#"{ "email": "a@b.co" }"#)
    XCTAssertEqual(p.email, "a@b.co")
    XCTAssertNil(p.provider)
    XCTAssertNil(p.fullName)
    XCTAssertNil(p.id)
  }
}
