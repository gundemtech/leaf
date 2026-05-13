import XCTest
@testable import LeafCore

final class AppleScriptAdapterRegistryTests: XCTestCase {
    func testEmptyRegistryShipsNoAdapters() {
        let reg = EmptyAppleScriptAdapterRegistry()
        XCTAssertTrue(reg.adapters.isEmpty)
    }

    func testEmptyRegistryIsSendableAcrossActorBoundary() {
        // Compile-time check: must conform to Sendable to pass into a detached task.
        let reg: any AppleScriptAdapterRegistry = EmptyAppleScriptAdapterRegistry()
        let exp = expectation(description: "task completes")
        Task.detached {
            _ = reg.adapters
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testMockAdapterReportsTargetBundleIDsAndEventKinds() {
        let adapter = MockObservation_Adapter()
        XCTAssertEqual(adapter.targetBundleIDs, ["com.example.app"])
        XCTAssertEqual(adapter.eventKinds, [.githubCommitPushed])
    }
}

/// Minimal in-test mock proving the protocol is usable as a public extension
/// point. Production adapters live in LeafCorePrivate.
private struct MockObservation: AdapterObservation, Hashable {
    let payload: String
}

private struct MockObservation_Adapter: AppleScriptAdapter {
    var targetBundleIDs: Set<String> = ["com.example.app"]
    var eventKinds: Set<ShareEventTypeKey> = [.githubCommitPushed]
    var pollIntervalSec: TimeInterval = 60.0
    var timeoutSec: Double = 1.0

    func tickScript(for bundleID: String) -> String { "" }
    func parse(_ descriptorData: Data, for bundleID: String) -> (any AdapterObservation)? {
        MockObservation(payload: "x")
    }
    func observe(
        _ observation: any AdapterObservation,
        nowMs: Int64,
        localAppsStore: LocalAppsStore
    ) -> [RawEvent] { [] }
}
