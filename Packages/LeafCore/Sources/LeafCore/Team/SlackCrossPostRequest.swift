// Phase Track-5 S6 — sender-side request value for Slack cross-post leg of
// DirectMessageService.send. UI populates after user picks a channel from
// SlackChannelsReader; service consults sender's stored Slack OAuth token,
// builds the Block Kit payload via CrossPostPayloadBuilder, forwards to the
// slack_post Edge Function. Failures are captured into CrossPostStatuses;
// the underlying direct_messages row persists regardless (§9.3).

import Foundation

public struct SlackCrossPostRequest: Sendable, Equatable {
    /// Slack channel ID, e.g. "C12345" (NOT "#channel-name" — the resolver
    /// in SlackChannelsReader returns the canonical ID).
    public let channelID: String

    /// Optional AttachedEventRef forwarded into the Block Kit context footer
    /// (CrossPostPayloadBuilder.slackPayload). Pure metadata — eventKind +
    /// externalRef only; never RawEvent payload fields (ADR-010 walkback).
    public let attachedEventRef: AttachedEventRef?

    public init(channelID: String, attachedEventRef: AttachedEventRef? = nil) {
        self.channelID = channelID
        self.attachedEventRef = attachedEventRef
    }
}
