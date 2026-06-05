import Foundation

/// Allow-list for the LLM egress projection (Track AI Coworker §8.1, fail-closed).
///
/// The projection is an **allow-list**, not a deny-list: only keys named here
/// (scalar facts) or covered by the self-authored carve-out reach the cloud;
/// every other key — including any future collector key — is dropped by default.
/// This mirrors the proven relay model (`TeamEventPayloadBuilder.allowedKeys`)
/// and is faithful to canon §4.1 ("Структурированное ≠ безопасное").
///
/// The starter set is deliberately MINIMAL (Phase P0). Full per-event-kind
/// classification of the ~150 `Schema.EventPayloadKeys` is incremental in
/// P1/P2; unclassified keys stay safe (dropped). Never add a free-text key
/// (names / titles / descriptions / urls / channel names) to `scalarFacts`.
public enum EgressFactAllowlist {

  /// Raw payload keys carrying only dry facts — counts / opaque or
  /// work-namespace ids / enums / ms-timestamps / booleans. Pass through under
  /// their raw names. (Sourced from `Schema.EventPayloadKeys` for verifiability.)
  public static let scalarFacts: Set<String> = [
    // identifiers (opaque / work-namespace)
    Schema.EventPayloadKeys.issueId,
    Schema.EventPayloadKeys.issueIdentifier,
    Schema.EventPayloadKeys.commentId,
    Schema.EventPayloadKeys.cycleId,
    Schema.EventPayloadKeys.projectId,
    Schema.EventPayloadKeys.teamId,
    Schema.EventPayloadKeys.alertNumber,
    // GitHub-collector top-level literals (numeric/opaque, deliberately not in
    // Schema.EventPayloadKeys). Kept narrow; never add a free-text literal here.
    "pr_number", "number", "sha",
    // counts
    Schema.EventPayloadKeys.additions,
    Schema.EventPayloadKeys.deletions,
    Schema.EventPayloadKeys.filesCount,
    Schema.EventPayloadKeys.mentionCount,
    Schema.EventPayloadKeys.linkCount,
    Schema.EventPayloadKeys.reactionCount,
    Schema.EventPayloadKeys.reactionDelta,
    Schema.EventPayloadKeys.issuesCompletedCount,
    Schema.EventPayloadKeys.completedCountDelta,
    Schema.EventPayloadKeys.keystrokeCount,
    Schema.EventPayloadKeys.mouseMoveCount,
    Schema.EventPayloadKeys.appSwitchCount,
    // enums / states / scalars
    Schema.EventPayloadKeys.prReviewState,
    Schema.EventPayloadKeys.toStateType,
    Schema.EventPayloadKeys.stateEnum,
    Schema.EventPayloadKeys.resolutionKind,
    Schema.EventPayloadKeys.relationKind,
    Schema.EventPayloadKeys.meetingState,
    Schema.EventPayloadKeys.buildState,
    Schema.EventPayloadKeys.deploymentState,
    Schema.EventPayloadKeys.alertSeverity,
    Schema.EventPayloadKeys.cycleNumber,
    Schema.EventPayloadKeys.progress,
    // ms timestamps / ts
    Schema.EventPayloadKeys.observedAtMs,
    Schema.EventPayloadKeys.receivedAtMs,
    Schema.EventPayloadKeys.readAtMs,
    Schema.EventPayloadKeys.startedAtMs,
    Schema.EventPayloadKeys.endsAtMs,
    Schema.EventPayloadKeys.completedAtMs,
    Schema.EventPayloadKeys.reactedAtMs,
    Schema.EventPayloadKeys.dueTs,
    Schema.EventPayloadKeys.completedTs,
    Schema.EventPayloadKeys.pinnedAtMs,
    Schema.EventPayloadKeys.savedAtMs,
  ]

  /// Truncation cap for a self-authored label (matches relay §6 budget).
  public static let selfAuthoredCap = 140

  /// §4.3 self-authored carve-out: `event_kind` → (raw SOURCE key, distinct
  /// OUTPUT key). The user's own commit subject / PR-issue title / branch is a
  /// label, not a body — but it lives under the SAME raw key (`title`/`branch`)
  /// that also holds *others'* content, so the discriminator is the kind, not
  /// the key. The label is re-emitted under a `self_authored_*` output key so a
  /// raw body/title key never appears verbatim in the projection.
  public static let selfAuthored: [String: (source: String, output: String)] = [
    "gh_commit_pushed": (source: "title", output: "self_authored_commit"),
    "gh_pr_opened": (source: "title", output: "self_authored_title"),
    "gh_issue_opened": (source: "title", output: "self_authored_title"),
    "gh_branch_created": (source: "branch", output: "self_authored_branch"),
  ]

  public static var selfAuthoredKinds: Set<String> { Set(selfAuthored.keys) }
  public static let selfAuthoredOutputKeys: Set<String> = [
    "self_authored_commit", "self_authored_title", "self_authored_branch",
  ]

  /// SSOT mirror of `Schema.EventPayloadKeys` body / free-text-label keys —
  /// the belt-and-braces fence: **no key here may ever appear as a projection
  /// OUTPUT key** (mirrors `TeamEventPayloadBuilder.bannedKeys`). Self-authored
  /// content rides only under `selfAuthoredOutputKeys`, never under these.
  public static let bodyFields: Set<String> = [
    Schema.EventPayloadKeys.body,
    Schema.EventPayloadKeys.bodyTruncated,
    Schema.EventPayloadKeys.attachmentsJson,
    Schema.EventPayloadKeys.commentBodiesJson,
    Schema.EventPayloadKeys.threadRepliesJson,
    Schema.EventPayloadKeys.messagesJson,
    Schema.EventPayloadKeys.notificationTitle,
    Schema.EventPayloadKeys.noteTitle,
    Schema.EventPayloadKeys.meetingTopic,
    Schema.EventPayloadKeys.channelName,
    Schema.EventPayloadKeys.gistDescription,
    "title",  // raw PR/issue/commit/bookmark/tab title (free text)
    "branch",  // raw branch label (free text)
  ]
}
