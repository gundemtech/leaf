import XCTest
@testable import LeafCore

final class JetBrainsStateMachineTests: XCTestCase {
    func testFirstObservationEmits() {
        var sm = JetBrainsStateMachine()
        let events = sm.observe(JetBrainsObservation(ideBundleID: "com.jetbrains.intellij", projectName: "P", activeDocPath: "/x"), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "jetbrains_active_doc_changed")
        XCTAssertEqual(events[0].payload["ide_bundle_id"], "com.jetbrains.intellij")
        XCTAssertEqual(events[0].payload["project"], "P")
        XCTAssertEqual(events[0].payload["doc_path"], "/x")
    }

    func testIdempotentEmitsNothing() {
        var sm = JetBrainsStateMachine()
        let obs = JetBrainsObservation(ideBundleID: "com.jetbrains.pycharm", projectName: "P", activeDocPath: "/x")
        _ = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000).count, 0)
    }

    func testIDESwitchEmits() {
        var sm = JetBrainsStateMachine()
        _ = sm.observe(JetBrainsObservation(ideBundleID: "com.jetbrains.intellij", projectName: "P", activeDocPath: "/x"), nowMs: 1000)
        let events = sm.observe(JetBrainsObservation(ideBundleID: "com.jetbrains.pycharm", projectName: "P", activeDocPath: "/x"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["ide_bundle_id"], "com.jetbrains.pycharm")
    }

    func testDocPathChangeEmits() {
        var sm = JetBrainsStateMachine()
        _ = sm.observe(JetBrainsObservation(ideBundleID: "com.jetbrains.intellij", projectName: "P", activeDocPath: "/x"), nowMs: 1000)
        let events = sm.observe(JetBrainsObservation(ideBundleID: "com.jetbrains.intellij", projectName: "P", activeDocPath: "/y"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["doc_path"], "/y")
    }
}
