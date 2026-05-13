import XCTest
@testable import LeafCore

final class WiFiStateMachineTests: XCTestCase {

    func testFirstObservationReturnsNil() {
        var sm = WiFiStateMachine()
        XCTAssertNil(sm.observe(WiFiSnapshot(powerOn: true, mode: .station)))
    }

    func testPoweredOnStationEmitsConnectedAfterDisconnect() {
        var sm = WiFiStateMachine()
        _ = sm.observe(WiFiSnapshot(powerOn: false, mode: .none))
        XCTAssertEqual(
            sm.observe(WiFiSnapshot(powerOn: true, mode: .station)),
            .connected
        )
    }

    func testPowerOffMidStationEmitsDisconnected() {
        var sm = WiFiStateMachine()
        _ = sm.observe(WiFiSnapshot(powerOn: true, mode: .station))
        XCTAssertEqual(
            sm.observe(WiFiSnapshot(powerOn: false, mode: .station)),
            .disconnected
        )
    }

    func testModeChangeWhileConnectedDropsToDisconnected() {
        var sm = WiFiStateMachine()
        _ = sm.observe(WiFiSnapshot(powerOn: true, mode: .station))
        // Mode change from station to hostAP (sharing iPhone hotspot, etc).
        XCTAssertEqual(
            sm.observe(WiFiSnapshot(powerOn: true, mode: .hostAP)),
            .disconnected
        )
    }

    func testSameStableStateNoEmit() {
        var sm = WiFiStateMachine()
        _ = sm.observe(WiFiSnapshot(powerOn: true, mode: .station))
        XCTAssertNil(sm.observe(WiFiSnapshot(powerOn: true, mode: .station)))
        _ = sm.observe(WiFiSnapshot(powerOn: false, mode: .none))
        XCTAssertNil(sm.observe(WiFiSnapshot(powerOn: false, mode: .ibss)))
    }
}
