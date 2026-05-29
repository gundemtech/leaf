import XCTest

@testable import LeafCore

final class ZoomMeetingTopicRedactorProtocolTests: XCTestCase {
    func testIdentityPassesThroughAnyString() {
        let r = IdentityZoomMeetingTopicRedactor()
        XCTAssertEqual(r.redact(""), "")
        XCTAssertEqual(r.redact("Q1 Planning"), "Q1 Planning")
        XCTAssertEqual(
            r.redact("Alex Rivera's Personal Meeting Room"),
            "Alex Rivera's Personal Meeting Room")
    }

    func testIdentitySatisfiesProtocolAsExistential() {
        let r: any ZoomMeetingTopicRedactor = IdentityZoomMeetingTopicRedactor()
        XCTAssertEqual(r.redact("test"), "test")
    }
}
