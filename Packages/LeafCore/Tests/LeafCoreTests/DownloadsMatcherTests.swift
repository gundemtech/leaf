import XCTest

@testable import LeafCore

final class DownloadsMatcherTests: XCTestCase {

    private let matcher = DownloadsMatcher()
    private let createdFlag = DownloadsMatcher.createdFlag

    func testCreatedFileNonHiddenEmits() {
        XCTAssertTrue(matcher.shouldEmit(eventFlags: createdFlag, isDirectory: false, filename: "report.pdf"))
    }

    func testDirectoryRejected() {
        XCTAssertFalse(matcher.shouldEmit(eventFlags: createdFlag, isDirectory: true, filename: "subfolder"))
    }

    func testHiddenFileRejected() {
        XCTAssertFalse(matcher.shouldEmit(eventFlags: createdFlag, isDirectory: false, filename: ".hidden"))
    }

    func testDsStoreRejected() {
        XCTAssertFalse(matcher.shouldEmit(eventFlags: createdFlag, isDirectory: false, filename: ".DS_Store"))
    }

    func testModifiedOnlyEventRejected() {
        // .itemModified flag = 0x1000; w/o createdFlag → don't emit
        XCTAssertFalse(matcher.shouldEmit(eventFlags: 0x1000, isDirectory: false, filename: "report.pdf"))
    }
}
