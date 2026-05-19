import XCTest

@testable import LeafCore

final class XcodeStateMachineTests: XCTestCase {
    func testFirstObservationEmitsBothEvents() {
        var sm = XcodeStateMachine()
        let obs = XcodeObservation(activeDocPath: "/p", projectName: "Pj", schemeName: "S", buildState: .idle)
        let events = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].payload["event_kind"], "xcode_active_doc_changed")
        XCTAssertEqual(events[1].payload["event_kind"], "xcode_build_state_changed")
    }

    func testIdempotentObservationEmitsNothing() {
        var sm = XcodeStateMachine()
        let obs = XcodeObservation(activeDocPath: "/p", projectName: "Pj", schemeName: "S", buildState: .idle)
        _ = sm.observe(obs, nowMs: 1000)
        let events = sm.observe(obs, nowMs: 2000)
        XCTAssertEqual(events.count, 0)
    }

    func testDocChangeEmitsDocOnly() {
        var sm = XcodeStateMachine()
        _ = sm.observe(
            XcodeObservation(activeDocPath: "/a", projectName: "P", schemeName: "S", buildState: .idle), nowMs: 1000)
        let events = sm.observe(
            XcodeObservation(activeDocPath: "/b", projectName: "P", schemeName: "S", buildState: .idle), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "xcode_active_doc_changed")
        XCTAssertEqual(events[0].payload["doc_path"], "/b")
    }

    func testBuildStateChangeEmitsBuildOnly() {
        var sm = XcodeStateMachine()
        _ = sm.observe(
            XcodeObservation(activeDocPath: "/p", projectName: "P", schemeName: "S", buildState: .idle), nowMs: 1000)
        let events = sm.observe(
            XcodeObservation(activeDocPath: "/p", projectName: "P", schemeName: "S", buildState: .running), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "xcode_build_state_changed")
        XCTAssertEqual(events[0].payload["build_state"], "running")
    }

    func testBothChangeEmitsBoth() {
        var sm = XcodeStateMachine()
        _ = sm.observe(
            XcodeObservation(activeDocPath: "/p", projectName: "P", schemeName: "S", buildState: .idle), nowMs: 1000)
        let events = sm.observe(
            XcodeObservation(activeDocPath: "/q", projectName: "Q", schemeName: "S2", buildState: .succeeded),
            nowMs: 2000)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            Set(events.compactMap { $0.payload["event_kind"] }),
            ["xcode_active_doc_changed", "xcode_build_state_changed"])
    }

    // MARK: - Track-9 T1: line field

    func testStateMachineEmitsLineWhenProvided() {
        var sm = XcodeStateMachine()
        let obs = XcodeObservation(
            activeDocPath: "/p/File.swift",
            projectName: "Pj",
            schemeName: "S",
            buildState: .idle,
            line: 142
        )
        let events = sm.observe(obs, nowMs: 1000)
        let docEvent = events.first { $0.payload["event_kind"] == "xcode_active_doc_changed" }!
        XCTAssertEqual(docEvent.payload["line"], "142")
    }

    func testStateMachineOmitsLineWhenNil() {
        var sm = XcodeStateMachine()
        let obs = XcodeObservation(
            activeDocPath: "/p/File.swift",
            projectName: "Pj",
            schemeName: "S",
            buildState: .idle,
            line: nil
        )
        let events = sm.observe(obs, nowMs: 1000)
        let docEvent = events.first { $0.payload["event_kind"] == "xcode_active_doc_changed" }!
        XCTAssertNil(docEvent.payload["line"])
    }

    func testStateMachineDocChangeNotTriggeredByLineChange() {
        var sm = XcodeStateMachine()
        _ = sm.observe(
            XcodeObservation(activeDocPath: "/p/File.swift", projectName: "Pj", schemeName: "S", buildState: .idle, line: 1),
            nowMs: 1000)
        let events = sm.observe(
            XcodeObservation(activeDocPath: "/p/File.swift", projectName: "Pj", schemeName: "S", buildState: .idle, line: 50),
            nowMs: 2000)
        XCTAssertTrue(events.allSatisfy { $0.payload["event_kind"] != "xcode_active_doc_changed" })
    }
}
