import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryD3SlackTests: XCTestCase {
    func testRegistrySize116AfterD3Slack() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 156,
                       "97 (post-D2) + 19 (D3 Slack) + 9 (S1) + 14 (S2) + 13 (S3) + 4 (P6) = 156")
    }

    func testTwoLegacySlackKindsHaveCanonicalRawValues() {
        XCTAssertEqual(ShareEventTypeKey.slackMessageAuthored.rawValue,
                       "slack_message_authored_aggregate")
        XCTAssertEqual(ShareEventTypeKey.slackHuddleStateChange.rawValue,
                       "slack_huddle_state_change")
    }

    func testNineteenNewD3KeysPresent() {
        let expected = [
            "slack_reaction_added",
            "slack_pin_added", "slack_pin_removed",
            "slack_bookmark_added", "slack_bookmark_removed",
            "slack_reminder_created", "slack_reminder_completed",
            "slack_message_scheduled", "slack_message_sent_scheduled",
            "slack_item_saved", "slack_item_unsaved",
            "slack_channel_joined", "slack_channel_left",
            "slack_canvas_created", "slack_canvas_edited",
            "slack_custom_emoji_added",
            "slack_usergroup_membership_changed",
            "slack_channel_renamed", "slack_channel_archived"
        ]
        let allRaws = Set(ShareEventTypeKey.allCases.map(\.rawValue))
        for r in expected {
            XCTAssertTrue(allRaws.contains(r), "Missing D3 Slack rawValue: \(r)")
        }
    }

    func testAllNineteenNewD3SlackKindsDefaultOff() {
        let d3New: Set<String> = [
            "slack_reaction_added",
            "slack_pin_added", "slack_pin_removed",
            "slack_bookmark_added", "slack_bookmark_removed",
            "slack_reminder_created", "slack_reminder_completed",
            "slack_message_scheduled", "slack_message_sent_scheduled",
            "slack_item_saved", "slack_item_unsaved",
            "slack_channel_joined", "slack_channel_left",
            "slack_canvas_created", "slack_canvas_edited",
            "slack_custom_emoji_added",
            "slack_usergroup_membership_changed",
            "slack_channel_renamed", "slack_channel_archived"
        ]
        for entry in ShareEventTypeDefaults.all where d3New.contains(entry.key.rawValue) {
            XCTAssertFalse(entry.defaultEnabled,
                "D3 Slack key \(entry.key.rawValue) should default OFF (per ADR-020 — capture locally, share selectively)")
        }
    }
}
