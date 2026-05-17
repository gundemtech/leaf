import XCTest

@testable import LeafCore

/// Phase Track-4 S2 — exercises `AppleScriptDispatchLogic` invariants via
/// mock adapters. The actual `AppleScriptCollector` in LeafAgent is a thin
/// wrapper around this logic + a polling task per adapter.
final class AppleScriptCollectorDispatchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    @MainActor
    override func setUp() async throws {
        suiteName = "applescript.dispatch.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testSkipsIfDisabled() async {
        let bridge = AppleScriptBridge(executor: { _ in
            XCTFail("bridge invoked despite isEnabled=false")
            return .unavailable
        })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        // store.isEnabled defaults to false
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.example.x"])
        let out = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 1_000_000
        )
        XCTAssertTrue(out.events.isEmpty)
        XCTAssertTrue(out.diagnostics.isEmpty)
        // Permission state unchanged
        if case .notRequested = perm.cachedState(for: "com.example.x") {
        } else {
            XCTFail("expected unchanged .notRequested")
        }
    }

    @MainActor
    func testSkipsIfRecentlyDenied() async {
        let bridge = AppleScriptBridge(executor: { _ in
            XCTFail("bridge invoked despite recent denial")
            return .unavailable
        })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.example.x", true)
        perm.record(.denied(1_000_000), for: "com.example.x", nowMs: 1_000_000)
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.example.x"])
        let out = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 1_500_000  // 0.5h after denial — well within 24h
        )
        XCTAssertTrue(out.events.isEmpty)
    }

    @MainActor
    func testRecordsGrantedOnSuccess() async {
        let bridge = AppleScriptBridge(executor: { _ in
            .success(descriptorData: Data([0x01]))
        })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.example.x", true)
        var adapter: any AppleScriptAdapter = SpyAdapter(
            targetBundleIDs: ["com.example.x"],
            emitOnObserve: [
                RawEvent(signalType: .attention, bundleID: "com.example.x", payload: ["event_kind": "spy_observed"])
            ]
        )
        let out = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 2_000_000
        )
        XCTAssertEqual(out.events.count, 1)
        XCTAssertEqual(out.events[0].payload["event_kind"], "spy_observed")
        if case .granted = perm.cachedState(for: "com.example.x") {
        } else {
            XCTFail("expected .granted on success")
        }
    }

    @MainActor
    func testRecordsDeniedOnDeniedResult() async {
        let bridge = AppleScriptBridge(executor: { _ in .denied })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.example.x", true)
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.example.x"])
        _ = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 3_000_000
        )
        if case .denied(let t) = perm.cachedState(for: "com.example.x") {
            XCTAssertEqual(t, 3_000_000)
        } else {
            XCTFail("expected .denied")
        }
    }

    @MainActor
    func testRecordsAppNotInstalledWhenLookupFails() async {
        let bridge = AppleScriptBridge(executor: { _ in
            XCTFail("bridge invoked despite app missing")
            return .unavailable
        })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.missing.x", true)
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.missing.x"])
        _ = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in false },
            nowMs: 4_000_000
        )
        if case .appNotInstalled = perm.cachedState(for: "com.missing.x") {
        } else {
            XCTFail("expected .appNotInstalled")
        }
    }

    @MainActor
    func testTimeoutDiagnosticEmitted() async {
        let bridge = AppleScriptBridge(executor: { _ in .timeout })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.example.x", true)
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.example.x"])
        let out = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 5_000_000
        )
        XCTAssertEqual(out.diagnostics, [.timeout(bundleID: "com.example.x")])
        // State unchanged — timeout is transient
        if case .notRequested = perm.cachedState(for: "com.example.x") {
        } else {
            XCTFail("expected unchanged on timeout")
        }
    }

    @MainActor
    func testUnavailableTerminalRecorded() async {
        let bridge = AppleScriptBridge(executor: { _ in .unavailable })
        let perm = AppleScriptPermissionStore(defaults: defaults)
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.example.x", true)
        var adapter: any AppleScriptAdapter = SpyAdapter(targetBundleIDs: ["com.example.x"])
        _ = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: perm,
            localAppsStore: store,
            isInstalled: { _ in true },
            nowMs: 6_000_000
        )
        if case .unavailable = perm.cachedState(for: "com.example.x") {
        } else {
            XCTFail("expected .unavailable")
        }
    }
}

// MARK: - Mock adapter

private struct SpyObservation: AdapterObservation, Hashable {
    let bundleID: String
}

private struct SpyAdapter: AppleScriptAdapter {
    let targetBundleIDs: Set<String>
    var eventKinds: Set<ShareEventTypeKey> = [.githubCommitPushed]
    var pollIntervalSec: TimeInterval = 60.0
    var timeoutSec: Double = 1.0
    var emitOnObserve: [RawEvent] = []

    init(targetBundleIDs: Set<String>, emitOnObserve: [RawEvent] = []) {
        self.targetBundleIDs = targetBundleIDs
        self.emitOnObserve = emitOnObserve
    }

    func tickScript(for bundleID: String) -> String { "" }
    func parse(_ descriptorData: Data, for bundleID: String) -> (any AdapterObservation)? {
        SpyObservation(bundleID: bundleID)
    }
    func observe(
        _ observation: any AdapterObservation,
        nowMs: Int64,
        localAppsStore: LocalAppsStore
    ) -> [RawEvent] {
        emitOnObserve
    }
}
