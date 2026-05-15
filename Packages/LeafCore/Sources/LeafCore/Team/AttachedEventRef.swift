// Phase Track-5 S6 — value type for an event attestation surfaced through
// cross-post payload assembly. The `eventKind` (e.g., "github_pr_opened")
// and `externalRef` (e.g., "gundemtech/leaf#142") are the ONLY surfaces in
// the cross-post output where a payload-style sentinel string can
// legitimately appear: Layer A/B chose to emit that kind, and the
// externalRef is the third-party-canonical id. The walkback fence
// (CrossPostPayloadLeakageTests) enforces that those fields never leak
// into other positions of the resulting Slack/Linear payload.

import Foundation

public struct AttachedEventRef: Sendable, Equatable {
    public let eventKind: String
    public let externalRef: String

    public init(eventKind: String, externalRef: String) {
        self.eventKind = eventKind
        self.externalRef = externalRef
    }
}
