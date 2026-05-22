// Track-10 T1 / C4 — public LeafCore value type for onboarding share-controls
// preset entries. Equatable/Hashable/Sendable conformances drive collection
// usage + SwiftUI ForEach. Codable intentionally dropped (no consumer — CTO
// finding #4 YAGNI).

import XCTest

@testable import LeafCore

final class BundleAppEntryTests: XCTestCase {
    func testInitWithDefaults_defaultEnabledTrue() {
        let entry = BundleAppEntry(bundleID: "com.example.IDE", displayName: "Example IDE")
        XCTAssertEqual(entry.bundleID, "com.example.IDE")
        XCTAssertEqual(entry.displayName, "Example IDE")
        XCTAssertTrue(entry.defaultEnabled, "Default enabled flag must be true when omitted")
    }

    func testInitExplicitFalse_defaultEnabledRespected() {
        let entry = BundleAppEntry(
            bundleID: "com.example.Tool", displayName: "Example Tool", defaultEnabled: false)
        XCTAssertFalse(entry.defaultEnabled)
    }

    func testEquatable_sameFieldsEqual_differentFieldsNotEqual() {
        let a = BundleAppEntry(bundleID: "x", displayName: "X", defaultEnabled: true)
        let b = BundleAppEntry(bundleID: "x", displayName: "X", defaultEnabled: true)
        let c = BundleAppEntry(bundleID: "y", displayName: "X", defaultEnabled: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashable_sameFieldsSameHash_distinctInSet() {
        let a = BundleAppEntry(bundleID: "x", displayName: "X", defaultEnabled: true)
        let b = BundleAppEntry(bundleID: "x", displayName: "X", defaultEnabled: true)
        let c = BundleAppEntry(bundleID: "y", displayName: "Y", defaultEnabled: false)
        let set: Set<BundleAppEntry> = [a, b, c]
        XCTAssertEqual(set.count, 2, "Equal entries must collapse in a Set")
    }
}
