// Phase Track-5 S6 — ADR-010 walkback fence for cross-post Slack + Linear
// payload assembly. Mirrors TeamEventPayloadLeakageTests (S5 precedent):
// pump synthetic inputs loaded with banned-key sentinels through the
// CrossPostPayloadBuilder pure functions; recursively walk the resulting
// JSON tree / scan the Linear description string; assert sentinels never
// appear except at legitimate attestation surfaces (AttachedEventRef refs
// in the footer line — Layer A/B legitimately chose to emit that event_kind).
//
// Symmetric с S5 TeamEventPayloadLeakageTests (`Tests/LeafCoreTests/`).

import XCTest
@testable import LeafCore

final class CrossPostPayloadLeakageTests: XCTestCase {

    // 12 banned-key sentinels — payload field names that must NEVER end up
    // serialized into Slack hybrid payload tree or Linear description text.
    private let bannedKeys: [String] = [
        "body",
        "file_contents",
        "note_body",
        "email_subject",
        "preview",
        "prompt",
        "response",
        "commit_message",
        "pr_body",
        "issue_body",
        "screenshot_path",
        "download_filename"
    ]

    private let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    /// Innocent user-authored content carefully chosen NOT to contain any
    /// banned-key string as a substring (so we can distinguish sentinel
    /// leakage from legitimate user input passthrough).
    private let innocentText = "Hi team — quick sync at 3pm?"

    // MARK: - Slack payload — sentinels injected as event kinds via AttachedEventRef

    /// AttachedEventRef.eventKind is the ONLY surface where a banned-key
    /// sentinel string can legitimately appear (Layer A/B chose to emit that
    /// kind; it's user-visible by definition). The walkback test ensures the
    /// sentinel only appears at that single attestation surface (the context
    /// footer text), never leaking elsewhere in the JSON tree.
    func testSlackPayload_SentinelAsEventKind_AppearsOnlyInFooter() {
        for sentinel in bannedKeys {
            let ref = AttachedEventRef(
                eventKind: sentinel,
                externalRef: "legit/ref#1"
            )
            let payload = CrossPostPayloadBuilder.slackPayload(
                channelID: "C1",
                messageText: innocentText,
                attachedEventRef: ref
            )

            let occurrences = countSentinelOccurrences(sentinel, in: payload)
            // Exactly ONE occurrence: in the context footer string
            // ("Sent via Leaf · `<sentinel> legit/ref#1`")
            XCTAssertEqual(
                occurrences, 1,
                "sentinel '\(sentinel)' expected exactly once in footer, found \(occurrences)"
            )

            // Confirm it appears specifically in the context footer (not the
            // section block, not channel, not top-level text).
            XCTAssertFalse(
                ((payload["text"] as? String) ?? "").contains(sentinel),
                "sentinel '\(sentinel)' leaked into top-level text"
            )
            XCTAssertFalse(
                ((payload["channel"] as? String) ?? "").contains(sentinel),
                "sentinel '\(sentinel)' leaked into channel"
            )

            let blocks = payload["blocks"] as? [[String: Any]]
            let sectionText = ((blocks?[0]["text"] as? [String: Any])?["text"] as? String) ?? ""
            XCTAssertFalse(
                sectionText.contains(sentinel),
                "sentinel '\(sentinel)' leaked into section block text"
            )

            let footerElements = blocks?[1]["elements"] as? [[String: Any]]
            let footerText = (footerElements?.first?["text"] as? String) ?? ""
            XCTAssertTrue(
                footerText.contains(sentinel),
                "sentinel '\(sentinel)' missing from context footer (where it should be)"
            )
        }
    }

    /// When no AttachedEventRef provided, NO sentinel can appear anywhere.
    func testSlackPayload_NoAttachedRef_NoSentinelsAnywhere() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: innocentText,
            attachedEventRef: nil
        )

        for sentinel in bannedKeys {
            let occurrences = countSentinelOccurrences(sentinel, in: payload)
            XCTAssertEqual(
                occurrences, 0,
                "sentinel '\(sentinel)' appeared in payload with no AttachedEventRef"
            )
        }
    }

    /// AttachedEventRef.externalRef is also a legitimate surface (e.g.,
    /// "gundemtech/leaf#142") — confirm sentinel injected as externalRef only
    /// appears at the footer attestation site, not leaking elsewhere.
    func testSlackPayload_SentinelAsExternalRef_AppearsOnlyInFooter() {
        for sentinel in bannedKeys {
            let ref = AttachedEventRef(
                eventKind: "github_pr_opened",
                externalRef: sentinel
            )
            let payload = CrossPostPayloadBuilder.slackPayload(
                channelID: "C1",
                messageText: innocentText,
                attachedEventRef: ref
            )

            // sentinel should appear exactly once — in footer
            let occurrences = countSentinelOccurrences(sentinel, in: payload)
            XCTAssertEqual(
                occurrences, 1,
                "sentinel '\(sentinel)' as externalRef expected exactly once in footer, found \(occurrences)"
            )
        }
    }

    // MARK: - Linear description — flat string walkback

    func testLinearDescription_SentinelAsEventKind_AppearsOnlyInLinkedEventLine() {
        for sentinel in bannedKeys {
            let ref = AttachedEventRef(
                eventKind: sentinel,
                externalRef: "legit/ref#1"
            )
            let description = CrossPostPayloadBuilder.linearDescription(
                messageText: innocentText,
                messageID: messageID,
                attachedEventRef: ref
            )

            // Exactly once on the "Linked event:" line
            let occurrences = description.components(separatedBy: sentinel).count - 1
            XCTAssertEqual(
                occurrences, 1,
                "sentinel '\(sentinel)' expected exactly once in description, found \(occurrences)"
            )

            // Body and footer attestation strings must not contain sentinel
            XCTAssertFalse(
                description.contains("\(sentinel)\n["),
                "sentinel '\(sentinel)' leaked into body section"
            )
        }
    }

    func testLinearDescription_NoAttachedRef_NoSentinelsAnywhere() {
        let description = CrossPostPayloadBuilder.linearDescription(
            messageText: innocentText,
            messageID: messageID,
            attachedEventRef: nil
        )
        for sentinel in bannedKeys {
            XCTAssertFalse(
                description.contains(sentinel),
                "sentinel '\(sentinel)' appeared in description with no AttachedEventRef"
            )
        }
    }

    // MARK: - User-authored body — sentinels pass through verbatim (CORRECT)

    /// Critical correctness check: user IS the source of messageText. If user
    /// types "body" or "preview" as part of their DM, it MUST pass through —
    /// user-authored content is not a banned key in the leakage sense.
    /// Verify this explicitly so we don't over-sanitize and break legit DMs.
    func testSlackPayload_SentinelInUserBody_PassesThroughVerbatim() {
        for sentinel in bannedKeys {
            let userBody = "Working on \(sentinel) handling today"
            let payload = CrossPostPayloadBuilder.slackPayload(
                channelID: "C1",
                messageText: userBody,
                attachedEventRef: nil
            )

            XCTAssertEqual(
                payload["text"] as? String, userBody,
                "user-authored sentinel '\(sentinel)' was incorrectly stripped from text"
            )

            let blocks = payload["blocks"] as? [[String: Any]]
            let sectionText = (blocks?[0]["text"] as? [String: Any])?["text"] as? String
            XCTAssertEqual(
                sectionText, userBody,
                "user-authored sentinel '\(sentinel)' was incorrectly stripped from section"
            )
        }
    }

    func testLinearDescription_SentinelInUserBody_PassesThroughVerbatim() {
        for sentinel in bannedKeys {
            let userBody = "Resolved the \(sentinel) bug — see PR"
            let description = CrossPostPayloadBuilder.linearDescription(
                messageText: userBody,
                messageID: messageID,
                attachedEventRef: nil
            )

            XCTAssertTrue(
                description.contains(userBody),
                "user-authored sentinel '\(sentinel)' missing from linear description"
            )
        }
    }

    // MARK: - Footer constants are NOT pulled from inputs

    /// "[Sent via Leaf — message <uuid>]" / "Sent via Leaf" / "Linked event:"
    /// must be hardcoded constants. Pump unusual inputs and assert these
    /// strings still render verbatim.
    func testSlackPayload_FooterConstantUnchangedByMaliciousInputs() {
        let weirdInputs: [String] = [
            "Sent via Leaf",
            "Linked event: fake",
            "",
            "\n\n\n",
            "🎉 emoji 🎉",
            "<script>alert(1)</script>",
            String(repeating: "x", count: 10_000)
        ]
        for body in weirdInputs {
            let payload = CrossPostPayloadBuilder.slackPayload(
                channelID: "C1",
                messageText: body,
                attachedEventRef: nil
            )

            // Footer text must be exactly "Sent via Leaf" regardless
            let blocks = payload["blocks"] as? [[String: Any]]
            let footerElements = blocks?[1]["elements"] as? [[String: Any]]
            let footer = footerElements?.first?["text"] as? String
            XCTAssertEqual(footer, "Sent via Leaf")
        }
    }

    func testLinearDescription_FooterConstantUnchangedByMaliciousInputs() {
        let weirdInputs: [String] = [
            "Sent via Leaf — message FAKE-UUID",
            "[Sent via Leaf — message x]",
            "Linked event: hijack",
            ""
        ]
        for body in weirdInputs {
            let description = CrossPostPayloadBuilder.linearDescription(
                messageText: body,
                messageID: messageID,
                attachedEventRef: nil
            )
            // The genuine "[Sent via Leaf — message <messageID>]" must appear
            // (the constant footer ALWAYS uses messageID, never user input)
            XCTAssertTrue(
                description.contains("[Sent via Leaf — message \(messageID.uuidString)]"),
                "footer constant missing or mutated for input '\(body)'"
            )
        }
    }

    /// Constant strings — `Sent via Leaf` / `Linked event:` / `—` em-dash —
    /// must appear regardless of input shape and must NOT come from
    /// attached event ref fields. Verify by pumping AttachedEventRef whose
    /// eventKind/externalRef contain those strings (legitimate user surface)
    /// and confirming the constant footer prefix is still there.
    func testSlackPayload_FooterPrefixIsConstant() {
        let ref = AttachedEventRef(
            eventKind: "Sent via Leaf",          // attempt to hijack
            externalRef: "Sent via Leaf · fake"
        )
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "msg",
            attachedEventRef: ref
        )
        let blocks = payload["blocks"] as? [[String: Any]]
        let footerElements = blocks?[1]["elements"] as? [[String: Any]]
        let footer = (footerElements?.first?["text"] as? String) ?? ""
        // Footer must START with "Sent via Leaf · `" — the literal constant prefix
        XCTAssertTrue(
            footer.hasPrefix("Sent via Leaf · `"),
            "footer prefix corrupted: '\(footer)'"
        )
    }

    // MARK: - Sentinel-substring false-positive regression (M18)

    /// Documents a gotcha in `countSentinelOccurrences`: substring matching
    /// over-counts when a sentinel like "preview" naturally appears inside
    /// an unrelated, legitimate event_kind such as "linear_preview_changed".
    /// The walker would tag the occurrence as a leak even though the
    /// kind is on Layer A/B's allowlist (the kind name is itself public
    /// metadata that Leaf has chosen to emit).
    ///
    /// The right invariant for the leakage suite is: "every sentinel
    /// occurrence is on the footer attestation surface". This test
    /// pumps a hypothetical future kind `linear_preview_changed` and
    /// confirms the substring "preview" appears exactly once + in the
    /// footer line (not section block / channel / text). The test guards
    /// against future regressions where the walker would erroneously
    /// flag legitimate-attestation surfaces as leaks.
    func testSlackPayload_SentinelSubstringInLegitimateEventKind_IsNotOverCounted() {
        let ref = AttachedEventRef(
            eventKind: "linear_preview_changed",   // legitimate kind whose name contains "preview" sentinel
            externalRef: "LEA-1"
        )
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "innocent body",
            attachedEventRef: ref
        )

        // The substring "preview" appears exactly once — within the
        // legitimate footer attestation, not as a banned-key leak.
        let occurrences = countSentinelOccurrences("preview", in: payload)
        XCTAssertEqual(
            occurrences, 1,
            "sentinel substring in legitimate kind expected once in footer, found \(occurrences)"
        )

        // Confirm the occurrence is on the footer line specifically.
        let blocks = payload["blocks"] as? [[String: Any]]
        let footerElements = blocks?[1]["elements"] as? [[String: Any]]
        let footerText = (footerElements?.first?["text"] as? String) ?? ""
        XCTAssertTrue(
            footerText.contains("linear_preview_changed"),
            "legitimate eventKind appears in footer (attestation), not a leak"
        )

        // And NOT on the section block / channel / top-level text.
        XCTAssertFalse(((payload["text"] as? String) ?? "").contains("preview"))
        XCTAssertFalse(((payload["channel"] as? String) ?? "").contains("preview"))
        let sectionText = ((blocks?[0]["text"] as? [String: Any])?["text"] as? String) ?? ""
        XCTAssertFalse(sectionText.contains("preview"))
    }

    // MARK: - Structural invariants — top-level shape and key set are constants

    func testSlackPayload_TopLevelKeysAreConstants() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "",
            attachedEventRef: nil
        )
        // Always exactly these 5 keys regardless of inputs
        let keys = Set(payload.keys)
        XCTAssertEqual(keys, Set(["channel", "text", "blocks", "unfurl_links", "unfurl_media"]))
    }

    func testSlackPayload_UnfurlSuppressionAlwaysOn() {
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: "C1",
            messageText: "https://example.com/secret",
            attachedEventRef: nil
        )
        XCTAssertEqual(payload["unfurl_links"] as? Bool, false)
        XCTAssertEqual(payload["unfurl_media"] as? Bool, false)
    }

    // MARK: - JSON tree walker

    /// Recursively walks an `Any` value (Dictionary / Array / String / other)
    /// and counts how many string leaves contain `needle` as a substring.
    /// Sub-occurrences (multiple in one string) count individually.
    private func countSentinelOccurrences(_ needle: String, in value: Any) -> Int {
        if let dict = value as? [String: Any] {
            var total = 0
            for (key, v) in dict {
                if key.contains(needle) { total += 1 }
                total += countSentinelOccurrences(needle, in: v)
            }
            return total
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countSentinelOccurrences(needle, in: $1) }
        }
        if let s = value as? String {
            return s.components(separatedBy: needle).count - 1
        }
        return 0
    }
}
