import XCTest

@testable import LeafCore

final class AccountProfileFormatTests: XCTestCase {
  private func profile(
    email: String? = nil, fullName: String? = nil, createdAt: String? = nil
  ) -> SupabaseUserProfile {
    SupabaseUserProfile(
      id: nil, email: email, fullName: fullName, provider: nil, createdAt: createdAt)
  }

  func testProviderLabel() {
    XCTAssertEqual(AccountProfileFormat.providerLabel("email"), "Email")
    XCTAssertEqual(AccountProfileFormat.providerLabel("google"), "Google")
    XCTAssertEqual(AccountProfileFormat.providerLabel("github"), "GitHub")
    XCTAssertEqual(AccountProfileFormat.providerLabel("azure"), "Azure")
    XCTAssertEqual(AccountProfileFormat.providerLabel(nil), "Email")
  }

  func testAccountName_prefersFullNameThenEmailLocalPart() {
    XCTAssertEqual(AccountProfileFormat.accountName(profile(fullName: "Sam Rivera")), "Sam Rivera")
    XCTAssertEqual(
      AccountProfileFormat.accountName(profile(email: "sam@x.co", fullName: "")), "sam")
    XCTAssertNil(AccountProfileFormat.accountName(profile()))
  }

  func testMemberSince_formatsISO() {
    XCTAssertEqual(
      AccountProfileFormat.memberSince(isoString: "2024-06-10T12:34:56.000Z"), "10 Jun 2024")
    XCTAssertEqual(
      AccountProfileFormat.memberSince(isoString: "2024-06-10T12:34:56Z"), "10 Jun 2024")
    XCTAssertNil(AccountProfileFormat.memberSince(isoString: nil))
    XCTAssertNil(AccountProfileFormat.memberSince(isoString: "garbage"))
  }
}
