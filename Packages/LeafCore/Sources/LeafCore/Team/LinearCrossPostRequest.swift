// Phase Track-5 S6 — sender-side request value for Linear cross-post leg of
// DirectMessageService.send. UI populates after user picks a Linear team
// (LinearTeamsReader) and optionally resolves an assignee via
// LinearUsersResolver. Service builds title + GFM description via
// CrossPostPayloadBuilder, forwards to the linear_create_issue Edge Function.
//
// A5: `idempotencyKey` is forwarded verbatim as IssueCreateInput.id — Linear
// treats identical id as idempotent, so a transient transport retry yields the
// same issue. Mac generates one UUIDv4 per send and surfaces failures via
// CrossPostStatuses; the underlying direct_messages row persists regardless.

import Foundation

public struct LinearCrossPostRequest: Sendable, Equatable {
    /// Linear team ID (e.g. "TEAM-…" UUID), surfaced by LinearTeamsReader.
    public let teamID: String

    /// Optional Linear user ID. nil = unassigned (Edge Function omits the
    /// assigneeId field entirely from the IssueCreateInput).
    public let assigneeID: String?

    /// A5: forwarded verbatim → IssueCreateInput.id. Caller-generated UUIDv4
    /// per send; identical key on retry produces the same issue.
    public let idempotencyKey: UUID

    /// Optional AttachedEventRef forwarded into the GFM description footer
    /// (CrossPostPayloadBuilder.linearDescription). Pure metadata — eventKind
    /// + externalRef only; never RawEvent payload fields (ADR-010 walkback).
    public let attachedEventRef: AttachedEventRef?

    public init(
        teamID: String,
        assigneeID: String? = nil,
        idempotencyKey: UUID = UUID(),
        attachedEventRef: AttachedEventRef? = nil
    ) {
        self.teamID = teamID
        self.assigneeID = assigneeID
        self.idempotencyKey = idempotencyKey
        self.attachedEventRef = attachedEventRef
    }
}
