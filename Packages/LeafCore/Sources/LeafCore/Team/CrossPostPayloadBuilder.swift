// Phase Track-5 S6 — pure-function payload assembly for Slack chat.postMessage
// hybrid payload (text fallback + Block Kit blocks per A2 brainstorm) +
// Linear GFM description (per A2 + A5 spec amendments).
//
// NO sender prefix:
//   - Slack user-token natively attributes posts to sender in Slack UI.
//   - Linear shows "Created by <user>" metadata bar.
// Therefore the body strings never embed a synthesized "<sender>:" prefix.
//
// The Linear description footer "---\n[Sent via Leaf — message <uuid>]" is
// the bi-directional handle (§4.5): a future Track 6 inbound Linear
// collector will parse the message UUID from issue body when state
// transitions to `done` and PATCH `direct_messages.done_at`.
//
// ADR-010 walkback: this builder takes only AttachedEventRef (event_kind +
// external_ref — both legitimate user-facing surfaces) plus user-authored
// messageText. It never reads RawEvent payload fields. The walkback fence
// (CrossPostPayloadLeakageTests) sentinel-injects RawEvent-adjacent fields
// to enforce.

import Foundation

public enum CrossPostPayloadBuilder {

    /// A2: Hybrid text + blocks payload for Slack chat.postMessage.
    /// - `text`: notification fallback (push, screen reader, mobile lock screen)
    /// - `blocks`: visual rendering (section + context footer)
    /// - `unfurl_*`: suppress link previews; backticks around event ref further
    ///   suppress unfurl on URL-shaped externalRefs
    /// NO sender prefix — user-token natively attributes sender in Slack UI.
    public static func slackPayload(
        channelID: String,
        messageText: String,
        attachedEventRef: AttachedEventRef?
    ) -> [String: Any] {
        let footer = attachedEventRef.map { ref in
            "Sent via Leaf · `\(ref.eventKind) \(ref.externalRef)`"
        } ?? "Sent via Leaf"

        let blocks: [[String: Any]] = [
            [
                "type": "section",
                "text": ["type": "mrkdwn", "text": messageText]
            ],
            [
                "type": "context",
                "elements": [
                    ["type": "mrkdwn", "text": footer]
                ]
            ]
        ]

        return [
            "channel": channelID,
            "text": messageText,
            "blocks": blocks,
            "unfurl_links": false,
            "unfurl_media": false
        ]
    }

    /// A2 / A5: Linear issue title — 80-char single-line, trimmed.
    /// Newlines collapsed to spaces (Linear titles are single-line).
    public static func linearTitle(messageText: String) -> String {
        let single = messageText.replacingOccurrences(of: "\n", with: " ")
        let trimmed = single.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(80))
    }

    /// A2 / A5: Linear issue description.
    ///   <body>
    ///   <empty line>
    ///   ---
    ///   [Sent via Leaf — message <uuid>]
    ///   [Linked event: <kind> <ref>]   ← only when attachedEventRef != nil
    ///
    /// GFM markdown supported. The "[Sent via Leaf — message <uuid>]" line
    /// is the inbound handle for Track 6 bi-directional state sync (§4.5).
    public static func linearDescription(
        messageText: String,
        messageID: UUID,
        attachedEventRef: AttachedEventRef?
    ) -> String {
        var sections: [String] = []
        sections.append(messageText)
        sections.append("")
        var footer = "---\n[Sent via Leaf — message \(messageID.uuidString)]"
        if let ref = attachedEventRef {
            footer += "\nLinked event: \(ref.eventKind) \(ref.externalRef)"
        }
        sections.append(footer)
        return sections.joined(separator: "\n")
    }
}
