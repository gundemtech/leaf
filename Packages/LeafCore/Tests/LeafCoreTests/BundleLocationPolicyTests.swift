// Agent watchdog track — location guard for SMAppService registration.
// SMAppService.register() re-points the BTM parent record at the registering
// bundle's path: a prod-bundle-id copy launched from /tmp, a DMG mount or a
// translocated path hijacks the record away from /Applications/Leaf.app and
// launchd crash-loops the agent (EX_CONFIG). Auto-register is therefore gated
// on a canonical install location; debug bundle ids keep their separate label
// and stay unrestricted.

import XCTest

@testable import LeafCore

final class BundleLocationPolicyTests: XCTestCase {
  private let home = "/Users/alice"

  // MARK: - isCanonical

  func testSystemApplicationsIsCanonical() {
    XCTAssertTrue(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Applications/Leaf.app", homePath: home))
  }

  func testNestedUnderSystemApplicationsIsCanonical() {
    XCTAssertTrue(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Applications/Utilities/Leaf.app", homePath: home))
  }

  func testHomeApplicationsIsCanonical() {
    XCTAssertTrue(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Users/alice/Applications/Leaf.app", homePath: home))
  }

  func testTmpXcarchiveIsNotCanonical() {
    // The live hijack case: a Products/Applications/ segment inside the
    // archive must not satisfy a naive "contains /Applications/" check.
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app",
        homePath: home))
  }

  func testPrivateTmpIsNotCanonical() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/private/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app",
        homePath: home))
  }

  func testDmgMountIsNotCanonical() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Volumes/Leaf 1.2/Leaf.app", homePath: home))
  }

  func testDownloadsIsNotCanonical() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Users/alice/Downloads/Leaf.app", homePath: home))
  }

  func testAppTranslocationIsNotCanonical() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath:
          "/private/var/folders/k1/x/T/AppTranslocation/9A1B/d/Leaf.app",
        homePath: home))
  }

  func testDerivedDataIsNotCanonical() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath:
          "/Users/alice/Library/Developer/Xcode/DerivedData/Leaf-abc/Build/Products/Debug/Leaf.app",
        homePath: home))
  }

  func testPrefixBoundaryApplicationsEvil() {
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/ApplicationsEvil/Leaf.app", homePath: home))
    XCTAssertFalse(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Users/alice/ApplicationsEvil/Leaf.app", homePath: home))
  }

  func testHomeWithTrailingSlashStillCanonical() {
    XCTAssertTrue(
      BundleLocationPolicy.isCanonical(
        bundlePath: "/Users/alice/Applications/Leaf.app", homePath: "/Users/alice/"))
  }

  // MARK: - shouldAutoRegister

  func testDebugBundleIDAlwaysAutoRegisters() {
    XCTAssertTrue(
      BundleLocationPolicy.shouldAutoRegister(
        bundleID: "tech.gundem.leaf.debug",
        bundlePath:
          "/Users/alice/Library/Developer/Xcode/DerivedData/Leaf-abc/Build/Products/Debug/Leaf.app",
        homePath: home,
        environment: [:]))
  }

  func testProdCanonicalAutoRegisters() {
    XCTAssertTrue(
      BundleLocationPolicy.shouldAutoRegister(
        bundleID: "tech.gundem.leaf",
        bundlePath: "/Applications/Leaf.app",
        homePath: home,
        environment: [:]))
  }

  func testProdNonCanonicalDoesNotAutoRegister() {
    XCTAssertFalse(
      BundleLocationPolicy.shouldAutoRegister(
        bundleID: "tech.gundem.leaf",
        bundlePath: "/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app",
        homePath: home,
        environment: [:]))
  }

  func testEnvOverrideAllowsNonCanonical() {
    XCTAssertTrue(
      BundleLocationPolicy.shouldAutoRegister(
        bundleID: "tech.gundem.leaf",
        bundlePath: "/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app",
        homePath: home,
        environment: ["LEAF_ALLOW_NONCANONICAL_REGISTER": "1"]))
  }

  func testEnvOverrideEmptyValueIgnored() {
    XCTAssertFalse(
      BundleLocationPolicy.shouldAutoRegister(
        bundleID: "tech.gundem.leaf",
        bundlePath: "/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app",
        homePath: home,
        environment: ["LEAF_ALLOW_NONCANONICAL_REGISTER": ""]))
  }
}
