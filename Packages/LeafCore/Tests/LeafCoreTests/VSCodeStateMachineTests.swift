import XCTest

@testable import LeafCore

final class VSCodeStateMachineTests: XCTestCase {

    func test_firstObservation_emitsEvent() {
        var sm = VSCodeStateMachine()
        let obs = VSCodeObservation(
            ideBundleID: "com.microsoft.VSCode",
            workspaceName: "leaf",
            fileBasename: "Foo.swift"
        )
        let events = sm.observe(obs, nowMs: 1_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "vscode_active_doc_changed")
        XCTAssertEqual(events[0].payload["ide_bundle_id"], "com.microsoft.VSCode")
        XCTAssertEqual(events[0].payload["workspace_name"], "leaf")
        XCTAssertEqual(events[0].payload["file_basename"], "Foo.swift")
    }

    func test_identicalObservation_suppresses() {
        var sm = VSCodeStateMachine()
        let obs = VSCodeObservation(
            ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf", fileBasename: "Foo.swift")
        _ = sm.observe(obs, nowMs: 1_000)
        let events = sm.observe(obs, nowMs: 2_000)
        XCTAssertTrue(events.isEmpty)
    }

    func test_fileChange_emits() {
        var sm = VSCodeStateMachine()
        _ = sm.observe(
            .init(ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf", fileBasename: "Foo.swift"), nowMs: 1_000)
        let events = sm.observe(
            .init(ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf", fileBasename: "Bar.swift"), nowMs: 2_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["file_basename"], "Bar.swift")
    }

    func test_workspaceChange_emits() {
        var sm = VSCodeStateMachine()
        _ = sm.observe(
            .init(ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf", fileBasename: "Foo.swift"), nowMs: 1_000)
        let events = sm.observe(
            .init(ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf-docs", fileBasename: "Foo.swift"),
            nowMs: 2_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["workspace_name"], "leaf-docs")
    }

    func test_perBundleIsolation_vscodeAndCursor() {
        var sm = VSCodeStateMachine()
        _ = sm.observe(
            .init(ideBundleID: "com.microsoft.VSCode", workspaceName: "leaf", fileBasename: "Foo.swift"), nowMs: 1_000)
        // Different bundle ID should always emit (separate Box).
        let events = sm.observe(
            .init(ideBundleID: "com.todesktop.230313mzl4w4u92", workspaceName: "leaf", fileBasename: "Foo.swift"),
            nowMs: 2_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["ide_bundle_id"], "com.todesktop.230313mzl4w4u92")
    }

    func test_omitsNilFieldsFromPayload() {
        var sm = VSCodeStateMachine()
        let obs = VSCodeObservation(ideBundleID: "com.microsoft.VSCode", workspaceName: nil, fileBasename: "Foo.swift")
        let events = sm.observe(obs, nowMs: 1_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].payload["workspace_name"])
        XCTAssertEqual(events[0].payload["file_basename"], "Foo.swift")
    }
}
