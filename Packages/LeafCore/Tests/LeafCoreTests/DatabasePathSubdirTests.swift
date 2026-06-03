import XCTest

@testable import LeafCore

/// Debug/prod data-dir isolation: a Debug build (bundle id contains ".debug")
/// must resolve to a DIFFERENT Application Support subdir than prod, so a dev
/// build can never open/clobber the prod SQLCipher events.sqlite (the 4KB-stub
/// corruption we hit). All three prod processes share "Leaf"; all three debug
/// processes share "Leaf-Debug".
final class DatabasePathSubdirTests: XCTestCase {

  func testProdBundleIDsUseLeaf() {
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf"), "Leaf")
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf.agent"), "Leaf")
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf.mcp"), "Leaf")
  }

  func testDebugBundleIDsUseLeafDebug() {
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf.debug"), "Leaf-Debug")
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf.debug.agent"), "Leaf-Debug")
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "tech.gundem.leaf.debug.mcp"), "Leaf-Debug")
  }

  func testNilOrUnknownDefaultsToLeaf() {
    XCTAssertEqual(DatabasePath.subdir(forBundleID: nil), "Leaf")
    XCTAssertEqual(DatabasePath.subdir(forBundleID: "com.apple.dt.xctest.tool"), "Leaf")
  }
}
