import XCTest

@testable import LeafCore

final class AttestedModeReaderTests: XCTestCase {
  private var suite: UserDefaults!
  private let suiteName = "leaf.attestedmode.test"

  override func setUp() {
    suite = UserDefaults(suiteName: suiteName)
    suite.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    suite.removePersistentDomain(forName: suiteName)
  }

  // The attested path is experimental → OFF unless explicitly enabled.
  func testDefaultFalseWhenAbsent() {
    XCTAssertFalse(AttestedModeReader.read(defaults: suite))
  }

  func testReadsTrue() {
    suite.set(true, forKey: AttestedModeReader.key)
    XCTAssertTrue(AttestedModeReader.read(defaults: suite))
  }

  func testReadsFalse() {
    suite.set(false, forKey: AttestedModeReader.key)
    XCTAssertFalse(AttestedModeReader.read(defaults: suite))
  }
}
