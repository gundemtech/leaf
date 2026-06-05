import XCTest

@testable import LeafCore

final class LLMEgressMoatTests: XCTestCase {
  /// Pre-push moat rule: no Share-Controls preset bundle IDs in the public repo.
  /// The real personal-app list lives only in the gitignored prod moat; the
  /// anti-under-redaction fence (non-empty, contains real personal apps) is in
  /// the moat test (LeafCorePrivateTests), not here.
  func testPublicSubstrateHasNoPersonalAppBundleIDs() {
    XCTAssertTrue(
      LLMEgressMoat.publicSubstrate.neverToCloudBundleIDs.isEmpty,
      "public substrate must not hardcode personal-app bundle IDs")
  }

  func testInjectedSetIsHonored() {
    let moat = LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"])
    XCTAssertTrue(moat.neverToCloudBundleIDs.contains("com.test.personal"))
  }
}
