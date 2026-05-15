// Phase Track-5 S6 — return-side outcome of cross-post triggers. Aggregated
// inside `SentDirectMessage.crossPostStatuses`. Each provider slot is nil
// when the caller did NOT request cross-post for that provider; otherwise
// it carries the full SlackCrossPostResult / LinearCrossPostResult including
// the success path (.ok=true) AND the error path (.ok=false + .error=...).
//
// Independence — Slack and Linear succeed or fail independently. One nil
// status does NOT imply the other was attempted (see test
// `send_with_crossPostSlackOnly_doesNotInvokeLinearTrigger`).
//
// Failure semantics: cross-post failure NEVER throws out of
// DirectMessageService.send and NEVER affects the underlying direct_messages
// row, mirror row, or APNs delivery — only this struct carries the result
// for UI rendering.

import Foundation

public struct CrossPostStatuses: Sendable, Equatable {
    /// nil = caller did not request Slack cross-post for this send.
    public let slack: SlackCrossPostResult?

    /// nil = caller did not request Linear cross-post for this send.
    public let linear: LinearCrossPostResult?

    public init(slack: SlackCrossPostResult? = nil, linear: LinearCrossPostResult? = nil) {
        self.slack = slack
        self.linear = linear
    }
}
