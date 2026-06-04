import XCTest
@testable import LeafCore

final class AppleScriptBridgeTests: XCTestCase {
    @MainActor
    func testTimeoutFiresWhenExecutorHangs() async {
        let bridge = AppleScriptBridge(executor: { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .success(descriptorData: Data())
        })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 0.05)
        if case .timeout = result {
            // PASS
        } else {
            XCTFail("expected .timeout, got \(result)")
        }
    }

    @MainActor
    func testSuccessReturnsDescriptorData() async {
        let bridge = AppleScriptBridge(executor: { _ in
            .success(descriptorData: Data([0x01, 0x02]))
        })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 1.0)
        if case .success(let data) = result {
            XCTAssertEqual(data, Data([0x01, 0x02]))
        } else {
            XCTFail("expected .success, got \(result)")
        }
    }

    @MainActor
    func testDeniedSurfaces() async {
        let bridge = AppleScriptBridge(executor: { _ in .denied })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 1.0)
        if case .denied = result { /* PASS */ } else { XCTFail("expected .denied") }
    }

    @MainActor
    func testAppNotRunningSurfaces() async {
        let bridge = AppleScriptBridge(executor: { _ in .appNotRunning })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 1.0)
        if case .appNotRunning = result { /* PASS */ } else { XCTFail("expected .appNotRunning") }
    }

    @MainActor
    func testScriptErrorSurfacesCodeAndMessage() async {
        let bridge = AppleScriptBridge(executor: { _ in
            .scriptError(code: -1700, message: "Can't make X into Y")
        })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 1.0)
        if case .scriptError(let code, let message) = result {
            XCTAssertEqual(code, -1700)
            XCTAssertTrue(message.contains("X into Y"))
        } else {
            XCTFail("expected .scriptError, got \(result)")
        }
    }

    @MainActor
    func testUnavailableSurfacesOnExecutorThrow() async {
        enum Mock: Error { case x }
        let bridge = AppleScriptBridge(executor: { _ in throw Mock.x })
        let result = await bridge.executeScript("(*ignored*)", timeoutSec: 1.0)
        if case .unavailable = result { /* PASS */ } else {
            XCTFail("expected .unavailable, got \(result)")
        }
    }

    @MainActor
    func testProductionExecutorCompletesOffMainWithoutDeadlock() async {
        // WS3: production() runs NSAppleScript off the main actor on its own
        // queue. `return 1` needs no app/TCC. The property under test: the
        // off-main continuation resumes (no deadlock/hang) — a broken dispatch
        // would surface as `.timeout` (the sentinel winning because the executor
        // child never completed). Any non-timeout result proves the path works.
        let bridge = AppleScriptBridge.production()
        let result = await bridge.executeScript("return 1", timeoutSec: 2.0)
        if case .timeout = result {
            XCTFail("off-main dispatch did not resume within budget (deadlock?)")
        }
    }

    @MainActor
    func testProductionExecutorConcurrentRealScriptsDoNotDeadlock() async {
        let bridge = AppleScriptBridge.production()
        async let a = bridge.executeScript("return 1", timeoutSec: 2.0)
        async let b = bridge.executeScript("return 2", timeoutSec: 2.0)
        let (ra, rb) = await (a, b)
        if case .timeout = ra { XCTFail("first off-main call timed out (deadlock?)") }
        if case .timeout = rb { XCTFail("second off-main call timed out (deadlock?)") }
    }

    @MainActor
    func testConcurrentInvocationsSucceed() async {
        let bridge = AppleScriptBridge(executor: { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .success(descriptorData: Data())
        })
        async let a = bridge.executeScript("(*1*)", timeoutSec: 1.0)
        async let b = bridge.executeScript("(*2*)", timeoutSec: 1.0)
        let (ra, rb) = await (a, b)
        if case .success = ra, case .success = rb { /* PASS */ } else {
            XCTFail("expected both .success, got \(ra) / \(rb)")
        }
    }
}
