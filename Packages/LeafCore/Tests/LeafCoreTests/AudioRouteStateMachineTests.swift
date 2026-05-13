import XCTest
@testable import LeafCore

final class AudioRouteStateMachineTests: XCTestCase {

    func testFirstObservationReturnsNil() {
        var sm = AudioRouteStateMachine()
        XCTAssertNil(sm.observe(.builtin))
    }

    func testBuiltinToHeadphonesEmits() {
        var sm = AudioRouteStateMachine()
        _ = sm.observe(.builtin)
        XCTAssertEqual(sm.observe(.headphones), .headphones)
    }

    func testHeadphonesToBuiltinEmits() {
        var sm = AudioRouteStateMachine()
        _ = sm.observe(.headphones)
        XCTAssertEqual(sm.observe(.builtin), .builtin)
    }

    func testSameCategoryRepeatedReturnsNil() {
        var sm = AudioRouteStateMachine()
        _ = sm.observe(.bluetooth)
        XCTAssertNil(sm.observe(.bluetooth))
        XCTAssertNil(sm.observe(.bluetooth))
    }

    func testUnknownToKnownTransitionEmits() {
        var sm = AudioRouteStateMachine()
        _ = sm.observe(.unknown)
        XCTAssertEqual(sm.observe(.bluetooth), .bluetooth)
    }
}
