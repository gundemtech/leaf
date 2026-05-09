// Phase Track-1 D1 — pin all 12 payload key string literals.

import XCTest
@testable import LeafCore

final class EventPayloadKeysTests: XCTestCase {
    func testKeyStability() {
        XCTAssertEqual(Schema.EventPayloadKeys.body, "body")
        XCTAssertEqual(Schema.EventPayloadKeys.bodyTruncated, "body_truncated")
        XCTAssertEqual(Schema.EventPayloadKeys.attachmentsJson, "attachments_json")
        XCTAssertEqual(Schema.EventPayloadKeys.commentBodiesJson, "comment_bodies_json")
        XCTAssertEqual(Schema.EventPayloadKeys.threadRepliesJson, "thread_replies_json")
        XCTAssertEqual(Schema.EventPayloadKeys.messagesJson, "messages_json")
        XCTAssertEqual(Schema.EventPayloadKeys.filesCount, "files_count")
        XCTAssertEqual(Schema.EventPayloadKeys.additions, "additions")
        XCTAssertEqual(Schema.EventPayloadKeys.deletions, "deletions")
        XCTAssertEqual(Schema.EventPayloadKeys.requestedReviewersJson, "requested_reviewers_json")
        XCTAssertEqual(Schema.EventPayloadKeys.mentionCount, "mention_count")
        XCTAssertEqual(Schema.EventPayloadKeys.linkCount, "link_count")
    }
}
