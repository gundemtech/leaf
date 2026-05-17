import Foundation

/// Phase Track-3 D3 — canonical Slack event_kind identity. RawValue is the
/// JSON `event_kind` literal stored in `events.payload_json.$.event_kind`.
///
/// Source of truth for: ShareEventTypeRegistry (case-by-case mirror),
/// M017 rename mapping coverage (only the legacyRenamed subset),
/// EventsFullTextStore body-kind dispatch (only body-bearing cases),
/// DispatchCoverageTests (the fence).
public enum SlackEventKindKey: String, CaseIterable, Sendable, Hashable {
    // MARK: - Hot tier (existing 8, renamed to slack_*)
    case slackMessageAuthored = "slack_message_authored_aggregate"
    case slackHuddleStateChange = "slack_huddle_state_change"
    case slackThreadReplyAggregate = "slack_thread_reply_aggregate"
    case slackStatusChange = "slack_status_change"
    case slackPresenceState = "slack_presence_state"
    case slackDNDState = "slack_dnd_state"
    case slackMentionReceivedAggregate = "slack_mention_received_aggregate"
    case slackFileUploadedAggregate = "slack_file_uploaded_aggregate"

    // MARK: - Warm tier (Tasks 12)
    case slackReactionAdded = "slack_reaction_added"
    case slackPinAdded = "slack_pin_added"
    case slackPinRemoved = "slack_pin_removed"
    case slackBookmarkAdded = "slack_bookmark_added"
    case slackBookmarkRemoved = "slack_bookmark_removed"
    case slackReminderCreated = "slack_reminder_created"
    case slackReminderCompleted = "slack_reminder_completed"
    case slackMessageScheduled = "slack_message_scheduled"
    case slackMessageSentScheduled = "slack_message_sent_scheduled"
    case slackItemSaved = "slack_item_saved"
    case slackItemUnsaved = "slack_item_unsaved"
    case slackChannelJoined = "slack_channel_joined"
    case slackChannelLeft = "slack_channel_left"

    // MARK: - Cold tier (Task 14)
    case slackCanvasCreated = "slack_canvas_created"
    case slackCanvasEdited = "slack_canvas_edited"
    case slackCustomEmojiAdded = "slack_custom_emoji_added"
    case slackUsergroupMembershipChanged = "slack_usergroup_membership_changed"
    case slackChannelRenamed = "slack_channel_renamed"
    case slackChannelArchived = "slack_channel_archived"

    /// Subset that existed pre-D3 but with non-canonical rawValue (renamed by M017).
    /// DispatchCoverageTests asserts M017.renameMap targets == this set 1:1.
    public static let legacyRenamed: Set<SlackEventKindKey> = [
        .slackMessageAuthored, .slackHuddleStateChange,
    ]

    /// Subset that ships a body field in payload — body-kind dispatch in
    /// EventsFullTextStore must handle each of these.
    ///
    /// Per ADR-010 §6: canvas titles + bookmark titles are user-named resources
    /// (not message content) and are explicitly allowed. Message body / file content
    /// / preview / reminder text / scheduled-message text are NOT body-bearing —
    /// dropped at provider boundary, never reach FTS.
    public static let bodyBearing: Set<SlackEventKindKey> = [
        .slackCanvasCreated, .slackCanvasEdited,
        .slackBookmarkAdded, .slackBookmarkRemoved,
    ]

    // Scope catalogues (`requiredCore` / `requiredOptional` / `requested()`)
    // moved to `SlackScopesService` in Task 8 — single source of truth for
    // OAuth scope sets mirrors the GitHub D2 separation precedent
    // (`GitHubScopesService` owns scope catalogues; `GitHubEventKindKey` does not).
}
