//
//  MirrorRetentionConfigTests.swift
//  Track 5 / S8 / T10 — closes 2× deferral (contract §13:479 → S5 spec §6
//  deferred-to-S8). Tests cover default fallback / valid stored value /
//  invalid value sanitization / setter persistence / setter invalid-no-op.
//

import XCTest
@testable import LeafCore

final class MirrorRetentionConfigTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MirrorRetentionConfig.userDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MirrorRetentionConfig.userDefaultsKey)
        super.tearDown()
    }

    func testRetentionDays_NoUserDefaultsValue_Returns90() {
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)
    }

    func testRetentionDays_ValidStoredValue_ReturnsStored() {
        UserDefaults.standard.set(30, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 30)

        UserDefaults.standard.set(60, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 60)

        UserDefaults.standard.set(90, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)

        UserDefaults.standard.set(180, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 180)

        UserDefaults.standard.set(365, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 365)
    }

    func testRetentionDays_InvalidValue_FallsBackToDefault() {
        UserDefaults.standard.set(0, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)

        UserDefaults.standard.set(42, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)

        UserDefaults.standard.set(-1, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)

        UserDefaults.standard.set(999, forKey: MirrorRetentionConfig.userDefaultsKey)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 90)
    }

    func testSetRetentionDays_ValidValue_Persists() {
        MirrorRetentionConfig.setRetentionDays(60)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 60)

        MirrorRetentionConfig.setRetentionDays(365)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 365)
    }

    func testSetRetentionDays_InvalidValue_NoChange() {
        // Seed with a known-good value first.
        MirrorRetentionConfig.setRetentionDays(60)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 60)

        // Invalid set should be a no-op (preserves 60, not write 42).
        MirrorRetentionConfig.setRetentionDays(42)
        XCTAssertEqual(MirrorRetentionConfig.retentionDays(), 60)
    }
}
