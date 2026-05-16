import XCTest
@testable import LeafCore

final class IDEStorageFeatureGateTests: XCTestCase {
    func test_disabledGate_returnsFalseBoth() async {
        let gate = DisabledIDEStorageFeatureGate()
        let v = await gate.vscodeStorageEnabled
        let j = await gate.jetbrainsStorageEnabled
        XCTAssertFalse(v)
        XCTAssertFalse(j)
    }
}
