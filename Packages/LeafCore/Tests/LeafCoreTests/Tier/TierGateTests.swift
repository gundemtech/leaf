//
//  TierGateTests.swift
//  Track 5 / S8 / T3 — TierGate static struct invariants.
//
//  Verifies default-tier resolution + UserDefaults round-trip + per-capability
//  helpers. Legacy `pro` value normalization (cross-spec reviewer IMP-1) is
//  the dedicated `testCurrent_LegacyProValue_FallsBackToTeam` case.
//

import XCTest
@testable import LeafCore

final class TierGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TierGate.userDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TierGate.userDefaultsKey)
        super.tearDown()
    }

    // MARK: - Default

    func testCurrent_NoUserDefaultsValue_ReturnsTeamDefault() {
        XCTAssertEqual(TierGate.current(), .team, "MVP default — early-access semantics per contract §15.3")
    }

    // MARK: - UserDefaults round-trip

    func testCurrent_FreeStored_ReturnsFree() {
        UserDefaults.standard.set("free", forKey: TierGate.userDefaultsKey)
        XCTAssertEqual(TierGate.current(), .free)
    }

    func testCurrent_TeamStored_ReturnsTeam() {
        UserDefaults.standard.set("team", forKey: TierGate.userDefaultsKey)
        XCTAssertEqual(TierGate.current(), .team)
    }

    func testCurrent_LegacyProValue_FallsBackToTeam() {
        UserDefaults.standard.set("pro", forKey: TierGate.userDefaultsKey)
        XCTAssertEqual(TierGate.current(), .team, "Legacy 'pro' rawValue should fall back to default tier")
    }

    func testCurrent_UnknownValue_FallsBackToTeam() {
        UserDefaults.standard.set("garbage", forKey: TierGate.userDefaultsKey)
        XCTAssertEqual(TierGate.current(), .team)
    }

    // MARK: - Capability helpers

    func testCanCreateWorkspace_TeamTier_ReturnsTrue() {
        UserDefaults.standard.set("team", forKey: TierGate.userDefaultsKey)
        XCTAssertTrue(TierGate.canCreateWorkspace())
    }

    func testCanCreateWorkspace_FreeTier_ReturnsFalse() {
        UserDefaults.standard.set("free", forKey: TierGate.userDefaultsKey)
        XCTAssertFalse(TierGate.canCreateWorkspace())
    }

    func testCanSendDM_TeamTier_ReturnsTrue() {
        UserDefaults.standard.set("team", forKey: TierGate.userDefaultsKey)
        XCTAssertTrue(TierGate.canSendDM())
    }

    func testCanSendDM_FreeTier_ReturnsFalse() {
        UserDefaults.standard.set("free", forKey: TierGate.userDefaultsKey)
        XCTAssertFalse(TierGate.canSendDM())
    }

    func testCanAcceptInvite_TeamTier_ReturnsTrue() {
        UserDefaults.standard.set("team", forKey: TierGate.userDefaultsKey)
        XCTAssertTrue(TierGate.canAcceptInvite())
    }

    func testCanAcceptInvite_FreeTier_ReturnsFalse() {
        UserDefaults.standard.set("free", forKey: TierGate.userDefaultsKey)
        XCTAssertFalse(TierGate.canAcceptInvite())
    }

    // MARK: - setTier

    func testSetTier_PersistsToUserDefaults() {
        TierGate.setTier(.free)
        XCTAssertEqual(UserDefaults.standard.string(forKey: TierGate.userDefaultsKey), "free")
        XCTAssertEqual(TierGate.current(), .free)

        TierGate.setTier(.team)
        XCTAssertEqual(UserDefaults.standard.string(forKey: TierGate.userDefaultsKey), "team")
        XCTAssertEqual(TierGate.current(), .team)
    }
}
