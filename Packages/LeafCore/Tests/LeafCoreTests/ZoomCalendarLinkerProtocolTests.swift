import XCTest

@testable import LeafCore

final class ZoomCalendarLinkerProtocolTests: XCTestCase {
    func testNoOpReturnsNilForAnyTimestamp() {
        let linker = NoOpZoomCalendarLinker()
        XCTAssertNil(linker.match(atMs: 0))
        XCTAssertNil(linker.match(atMs: 1_715_882_400_000))
        XCTAssertNil(linker.match(atMs: Int64.max))
    }

    func testNoOpSatisfiesProtocolAsExistential() {
        let linker: any ZoomCalendarLinker = NoOpZoomCalendarLinker()
        XCTAssertNil(linker.match(atMs: 0))
    }
}
