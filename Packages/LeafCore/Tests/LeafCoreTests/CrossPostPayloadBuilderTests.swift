// Phase Track-5 S6 — CrossPostPayloadBuilder pure-function payload assembly.
//
// Coverage:
//   - Slack hybrid text + Block Kit payload (A2 brainstorm: drop sender prefix,
//     hybrid notification fallback + visual blocks; unfurl suppression).
//   - Linear title (80-char single-line truncation).
//   - Linear description (GFM markdown + footer + optional attached event ref).
//   - Determinism on identical inputs.

import XCTest
@testable import LeafCore

final class CrossPostPayloadBuilderTests: XCTestCase {

    private let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Slack payload shape

    func testSlackPayload_WithoutAttachedRef_FooterIsSentViaLeaf() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C12345",
            messageText: "hello team",
            attachedEventRef: nil
        )

        // Walk: blocks[1].elements[0].text should be "Sent via Leaf"
        let blocks = payload["blocks"] as? [[String: Any]]
        XCTAssertNotNil(blocks)
        let contextElements = blocks?[1]["elements"] as? [[String: Any]]
        let footer = contextElements?.first?["text"] as? String
        XCTAssertEqual(footer, "Sent via Leaf")
    }

    func testSlackPayload_WithAttachedRef_FooterIncludesBacktickedRef() {
        let ref = AttachedEventRef(
            eventKind: "github_pr_opened",
            externalRef: "gundemtech/leaf#142"
        )
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C12345",
            messageText: "review please",
            attachedEventRef: ref
        )

        let blocks = payload["blocks"] as? [[String: Any]]
        let contextElements = blocks?[1]["elements"] as? [[String: Any]]
        let footer = contextElements?.first?["text"] as? String
        XCTAssertEqual(footer, "Sent via Leaf · `github_pr_opened gundemtech/leaf#142`")
    }

    func testSlackPayload_StructuralInvariants() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C99",
            messageText: "msg",
            attachedEventRef: nil
        )

        // Required top-level keys
        XCTAssertEqual(payload["channel"] as? String, "C99")
        XCTAssertEqual(payload["text"] as? String, "msg")
        XCTAssertNotNil(payload["blocks"])
        XCTAssertEqual(payload["unfurl_links"] as? Bool, false)
        XCTAssertEqual(payload["unfurl_media"] as? Bool, false)
    }

    func testSlackPayload_BlocksAreExactlyTwoElements() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "msg",
            attachedEventRef: nil
        )

        let blocks = payload["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 2)
        XCTAssertEqual(blocks?[0]["type"] as? String, "section")
        XCTAssertEqual(blocks?[1]["type"] as? String, "context")
    }

    func testSlackPayload_TextFieldIsMessageTextVerbatim_NoSenderPrefix() {
        // A2 brainstorm: user-token natively attributes sender. No prefix.
        let body = "Закончил OAuth"
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: body,
            attachedEventRef: nil
        )

        XCTAssertEqual(payload["text"] as? String, body)

        // Section block text should also be verbatim
        let blocks = payload["blocks"] as? [[String: Any]]
        let sectionText = (blocks?[0]["text"] as? [String: Any])?["text"] as? String
        XCTAssertEqual(sectionText, body)
    }

    func testSlackPayload_SectionBlockUsesMrkdwn() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "msg",
            attachedEventRef: nil
        )
        let blocks = payload["blocks"] as? [[String: Any]]
        let textDict = blocks?[0]["text"] as? [String: Any]
        XCTAssertEqual(textDict?["type"] as? String, "mrkdwn")
    }

    // MARK: - Linear title

    func testLinearTitle_TruncatesTo80Chars() {
        let long = String(repeating: "a", count: 500)
        let title = CrossPostPayloadBuilder.linearTitle(messageText: long)
        XCTAssertEqual(title.count, 80)
    }

    func testLinearTitle_ReplacesNewlinesWithSpace() {
        let multi = "line one\nline two\nline three"
        let title = CrossPostPayloadBuilder.linearTitle(messageText: multi)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertEqual(title, "line one line two line three")
    }

    func testLinearTitle_TrimsLeadingAndTrailingWhitespace() {
        let padded = "   surrounding spaces   "
        let title = CrossPostPayloadBuilder.linearTitle(messageText: padded)
        XCTAssertEqual(title, "surrounding spaces")
    }

    // MARK: - Linear description

    func testLinearDescription_IncludesBodyAndFooter() {
        let body = "Got OAuth merged."
        let description = CrossPostPayloadBuilder.linearDescription(
            messageText: body,
            messageID: messageID,
            attachedEventRef: nil
        )

        XCTAssertTrue(description.contains(body))
        XCTAssertTrue(description.contains("---"))
        XCTAssertTrue(description.contains("[Sent via Leaf — message \(messageID.uuidString)]"))
    }

    func testLinearDescription_WithAttachedRef_AppendsLinkedEventLine() {
        let ref = AttachedEventRef(
            eventKind: "github_pr_opened",
            externalRef: "gundemtech/leaf#142"
        )
        let description = CrossPostPayloadBuilder.linearDescription(
            messageText: "see attached PR",
            messageID: messageID,
            attachedEventRef: ref
        )

        XCTAssertTrue(description.contains("Linked event: github_pr_opened gundemtech/leaf#142"))
    }

    func testLinearDescription_WithoutAttachedRef_NoLinkedEventLine() {
        let description = CrossPostPayloadBuilder.linearDescription(
            messageText: "msg",
            messageID: messageID,
            attachedEventRef: nil
        )

        XCTAssertFalse(description.contains("Linked event:"))
    }

    func testLinearDescription_Deterministic() {
        let body = "Same inputs"
        let d1 = CrossPostPayloadBuilder.linearDescription(
            messageText: body,
            messageID: messageID,
            attachedEventRef: nil
        )
        let d2 = CrossPostPayloadBuilder.linearDescription(
            messageText: body,
            messageID: messageID,
            attachedEventRef: nil
        )
        XCTAssertEqual(d1, d2)
    }

    // MARK: - AttachedEventRef value type

    func testAttachedEventRef_Equality() {
        let a = AttachedEventRef(eventKind: "k", externalRef: "r")
        let b = AttachedEventRef(eventKind: "k", externalRef: "r")
        let c = AttachedEventRef(eventKind: "k", externalRef: "different")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
