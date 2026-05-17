// Packages/LeafCore/Tests/LeafCoreTests/SurfaceCardStateTests.swift
import XCTest
@testable import LeafCore

final class SurfaceCardStateTests: XCTestCase {

    private struct DummyPayload: Equatable, Sendable {
        let value: Int
    }

    func testDisabledIsNotEnabled() {
        let s: SurfaceCardState<DummyPayload> = .disabled
        XCTAssertFalse(s.isEnabled)
    }

    func testEnabledLoadingIsEnabled() {
        let s: SurfaceCardState<DummyPayload> = .enabledLoading
        XCTAssertTrue(s.isEnabled)
    }

    func testEnabledPopulatedExposesPayload() {
        let payload = DummyPayload(value: 7)
        let s: SurfaceCardState<DummyPayload> = .enabledPopulated(payload: payload)
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.payload, payload)
    }

    func testZeroTodayHasNoPayload() {
        let s: SurfaceCardState<DummyPayload> = .enabledZeroToday
        XCTAssertTrue(s.isEnabled)
        XCTAssertNil(s.payload)
    }

    func testErrorIsEnabledTrueButNoPayload() {
        // Error state implies the surface IS enabled (otherwise we'd render
        // .disabled instead). UI dispatches to inline banner inside card.
        let s: SurfaceCardState<DummyPayload> = .error(message: "oops")
        XCTAssertTrue(s.isEnabled)
        XCTAssertNil(s.payload)
    }
}
