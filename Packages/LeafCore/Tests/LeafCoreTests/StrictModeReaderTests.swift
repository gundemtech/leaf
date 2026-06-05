import XCTest

@testable import LeafCore

final class StrictModeReaderTests: XCTestCase {
  private var suite: UserDefaults!
  private let suiteName = "leaf.strictmode.test"

  override func setUp() {
    suite = UserDefaults(suiteName: suiteName)
    suite.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    suite.removePersistentDomain(forName: suiteName)
  }

  func testDefaultFalseWhenAbsent() {
    // §4.3: self-authored labels go by DEFAULT — strict mode is off unless set.
    XCTAssertFalse(StrictModeReader.read(defaults: suite))
  }

  func testReadsTrue() {
    suite.set(true, forKey: StrictModeReader.key)
    XCTAssertTrue(StrictModeReader.read(defaults: suite))
  }

  func testReadsFalse() {
    suite.set(false, forKey: StrictModeReader.key)
    XCTAssertFalse(StrictModeReader.read(defaults: suite))
  }
}
