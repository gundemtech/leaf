// Phase Track-6 P2 — XcodeBuildLifecycleStateMachine transition coverage.
import Testing
import Foundation
@testable import LeafCore

@Suite("XcodeBuildLifecycleStateMachine")
struct XcodeBuildLifecycleStateMachineTests {

    private func obs(
        scheme: String? = "Leaf",
        state: XcodeBuildState = .idle,
        bucket: RunDestinationBucket = .macos
    ) -> XcodeObservation {
        XcodeObservation(
            activeDocPath: nil,
            projectName: "Leaf",
            schemeName: scheme,
            buildState: state,
            runDestinationName: nil,
            runDestinationBucket: bucket
        )
    }

    @Test func firstObservation_emitsNothing() {
        var m = XcodeBuildLifecycleStateMachine()
        let events = m.observe(obs(state: .running), nowMs: 100)
        #expect(events.isEmpty)
    }

    @Test func idleToRunning_emitsBuildStarted() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(state: .idle), nowMs: 100)
        let e = m.observe(obs(state: .running), nowMs: 200)
        #expect(e.count == 1)
        let p = e[0].payload
        #expect(p["event_kind"] == "xcode_build_started")
        #expect(p["scheme"] == "Leaf")
        #expect(p["project"] == "Leaf")
        #expect(p["run_destination_bucket"] == "macos")
    }

    @Test func runningToSucceeded_emitsBuildFinished_withDuration() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(state: .idle), nowMs: 100)
        _ = m.observe(obs(state: .running), nowMs: 200)
        let e = m.observe(obs(state: .succeeded), nowMs: 5_200)
        #expect(e.count == 1)
        let p = e[0].payload
        #expect(p["event_kind"] == "xcode_build_finished")
        #expect(p["status"] == "succeeded")
        #expect(p["duration_ms"] == "5000")
        #expect(p["scheme"] == "Leaf")
    }

    @Test func runningToFailed_emitsBuildFinished_statusFailed() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(state: .idle), nowMs: 100)
        _ = m.observe(obs(state: .running), nowMs: 200)
        let e = m.observe(obs(state: .failed), nowMs: 800)
        #expect(e.first?.payload["status"] == "failed")
        #expect(e.first?.payload["duration_ms"] == "600")
    }

    @Test func schemeFlip_emitsSchemeChanged() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(scheme: "Leaf"), nowMs: 100)
        let e = m.observe(obs(scheme: "LeafAgent"), nowMs: 200)
        let sc = e.first { $0.payload["event_kind"] == "xcode_scheme_changed" }
        #expect(sc != nil)
        #expect(sc?.payload["scheme"] == "LeafAgent")
        #expect(sc?.payload["scheme_prev"] == "Leaf")
    }

    @Test func runDestinationBucketFlip_emitsChange() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(bucket: .macos), nowMs: 100)
        let e = m.observe(obs(bucket: .iosSimulator), nowMs: 200)
        let rd = e.first { $0.payload["event_kind"] == "xcode_run_destination_changed" }
        #expect(rd != nil)
        #expect(rd?.payload["run_destination_bucket"] == "ios_simulator")
        #expect(rd?.payload["run_destination_bucket_prev"] == "macos")
    }

    @Test func sameBucketDifferentRawName_suppressed() {
        var m = XcodeBuildLifecycleStateMachine()
        let a = XcodeObservation(
            activeDocPath: nil, projectName: nil, schemeName: "Leaf",
            buildState: .idle,
            runDestinationName: "iPhone 15 (Simulator)",
            runDestinationBucket: .iosSimulator
        )
        let b = XcodeObservation(
            activeDocPath: nil, projectName: nil, schemeName: "Leaf",
            buildState: .idle,
            runDestinationName: "iPhone 16 Pro (Simulator)",
            runDestinationBucket: .iosSimulator
        )
        _ = m.observe(a, nowMs: 100)
        let e = m.observe(b, nowMs: 200)
        #expect(e.isEmpty)
    }

    @Test func runDestinationName_neverInPayload() {
        var m = XcodeBuildLifecycleStateMachine()
        let a = XcodeObservation(
            activeDocPath: nil, projectName: nil, schemeName: "Leaf",
            buildState: .idle,
            runDestinationName: "Dmitrii's iPhone",
            runDestinationBucket: .iosDevice
        )
        _ = m.observe(a, nowMs: 100)
        let b = XcodeObservation(
            activeDocPath: nil, projectName: nil, schemeName: "Leaf",
            buildState: .running,
            runDestinationName: "Dmitrii's iPhone",
            runDestinationBucket: .iosDevice
        )
        let events = m.observe(b, nowMs: 200)
        for ev in events {
            for v in ev.payload.values {
                #expect(!v.contains("Dmitrii"))
            }
        }
    }

    @Test func multipleTransitionsSimultaneously() {
        var m = XcodeBuildLifecycleStateMachine()
        _ = m.observe(obs(scheme: "Leaf", state: .idle, bucket: .macos), nowMs: 100)
        let e = m.observe(obs(scheme: "LeafAgent", state: .running, bucket: .iosSimulator), nowMs: 200)
        let kinds = e.map { $0.payload["event_kind"] ?? "" }
        #expect(kinds.contains("xcode_scheme_changed"))
        #expect(kinds.contains("xcode_run_destination_changed"))
        #expect(kinds.contains("xcode_build_started"))
    }
}
