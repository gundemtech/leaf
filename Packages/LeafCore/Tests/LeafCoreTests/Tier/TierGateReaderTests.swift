//
//  TierGateReaderTests.swift
//  Track 5 / S8 / T3 — @Observable wrapper around TierGate. Tests init reads,
//  manual refresh, capability helpers.
//
//  NotificationCenter-driven auto-refresh is exercised in T4 wiring smoke (no
//  reliable XCTest hook for `UserDefaults.didChangeNotification` cross-process);
//  the unit suite verifies the `refresh()` codepath that the notification
//  handler invokes.
//

import XCTest
@testable import LeafCore

@MainActor
final class TierGateReaderTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: TierGate.userDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: TierGate.userDefaultsKey)
    }

    func testInit_ReadsCurrentTier_DefaultTeam() {
        let reader = TierGateReader()
        XCTAssertEqual(reader.tier, .team)
    }

    func testInit_ReadsCurrentTier_FreeStored() {
        TierGate.setTier(.free)
        let reader = TierGateReader()
        XCTAssertEqual(reader.tier, .free)
    }

    func testRefresh_AfterExternalChange_UpdatesObservable() {
        let reader = TierGateReader()
        XCTAssertEqual(reader.tier, .team)

        TierGate.setTier(.free)
        reader.refresh()
        XCTAssertEqual(reader.tier, .free)

        TierGate.setTier(.team)
        reader.refresh()
        XCTAssertEqual(reader.tier, .team)
    }

    func testCapabilityHelpers_ReflectTier() {
        TierGate.setTier(.free)
        let reader = TierGateReader()
        XCTAssertFalse(reader.canCreateWorkspace)
        XCTAssertFalse(reader.canSendDM)
        XCTAssertFalse(reader.canAcceptInvite)

        TierGate.setTier(.team)
        reader.refresh()
        XCTAssertTrue(reader.canCreateWorkspace)
        XCTAssertTrue(reader.canSendDM)
        XCTAssertTrue(reader.canAcceptInvite)
    }
}
