import XCTest
@testable import LeafCore

/// Phase 4.10.A — pure mapper from raw event rows to ActivityFeedEntry.
///
/// Three responsibilities under test:
///  1. Each known event_kind produces the expected primary/secondary pair.
///  2. State-pulse event_kinds are skipped (return nil).
///  3. ADR-010 sentinel-injection: payload fields the mapper does NOT read
///     must never bleed into the visible row strings — even if a future
///     collector mistakenly stores a body / preview / description.
final class ActivityFeedMapperTests: XCTestCase {

    private let ts: Int64 = 1_700_000_000_000

    // MARK: - Attention

    func testMapsAttentionToLocalEntry() {
        let entry = ActivityFeedMapper.map(
            id: 1,
            timestampMs: ts,
            signalType: "attention",
            bundleID: "com.apple.Safari",
            payloadJSON: "{}"
        )
        XCTAssertEqual(entry?.provider, .local)
        XCTAssertEqual(entry?.bundleID, "com.apple.Safari")
        XCTAssertEqual(entry?.primaryText, "com.apple.Safari")
    }

    func testAttentionDropsRowWithoutBundleID() {
        XCTAssertNil(ActivityFeedMapper.map(
            id: 1, timestampMs: ts, signalType: "attention", bundleID: nil, payloadJSON: "{}"
        ))
    }

    // MARK: - Linear

    func testMapsLinearStatusTransition() {
        let payload = #"{"source":"linear","event_kind":"status_transition","issue_key":"ENG-1234","to_state_name":"In Review","from_state_name":"In Progress"}"#
        let entry = ActivityFeedMapper.map(
            id: 10, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .linear)
        XCTAssertEqual(entry?.eventKind, "status_transition")
        XCTAssertEqual(entry?.primaryText, "ENG-1234 → In Review")
        XCTAssertEqual(entry?.secondaryText, "from In Progress")
    }

    func testMapsLinearLabelAdded() {
        let payload = #"{"source":"linear","event_kind":"linear_label_added","issue_key":"ENG-9","label_name":"bug"}"#
        let entry = ActivityFeedMapper.map(
            id: 11, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "ENG-9 +bug")
    }

    func testMapsLinearAssigneeChangedAnonymizesViaBucket() {
        let payload = #"{"source":"linear","event_kind":"linear_assignee_changed","issue_key":"ENG-5","bucket":"self"}"#
        let entry = ActivityFeedMapper.map(
            id: 12, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "ENG-5 → assigned to self")
    }

    // MARK: - GitHub

    func testMapsGitHubPROpened() {
        let payload = #"{"source":"github","event_kind":"gh_pr_opened","repo":"gundemtech/leaf","number":"142"}"#
        let entry = ActivityFeedMapper.map(
            id: 20, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .github)
        XCTAssertEqual(entry?.primaryText, "gundemtech/leaf #142: opened")
    }

    func testMapsGitHubCommitPushed() {
        let payload = #"{"source":"github","event_kind":"gh_commit_pushed","repo":"gundemtech/leaf","branch":"main","sha":"abcdef1234567890"}"#
        let entry = ActivityFeedMapper.map(
            id: 21, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "gundemtech/leaf: pushed to main")
        XCTAssertEqual(entry?.secondaryText, "abcdef1")
    }

    func testMapsUnknownGitHubKindFallsBackToGenericRow() {
        let payload = #"{"source":"github","event_kind":"foo_bar","repo":"r/x","number":"7"}"#
        let entry = ActivityFeedMapper.map(
            id: 22, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "r/x #7: foo bar")
    }

    // MARK: - Slack

    func testMapsSlackMessageAuthoredAggregate() {
        let payload = #"{"source":"slack","event_kind":"slack_message_authored_aggregate","channel_name":"engineering","count":"5","reactions_count":"3"}"#
        let entry = ActivityFeedMapper.map(
            id: 30, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .slack)
        XCTAssertEqual(entry?.primaryText, "engineering: 5 messages")
        XCTAssertEqual(entry?.secondaryText, "3 reactions")
    }

    func testMapsHuddleStateChange() {
        let payload = #"{"source":"slack","event_kind":"slack_huddle_state_change","state":"in_a_huddle"}"#
        let entry = ActivityFeedMapper.map(
            id: 31, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Huddle: in_a_huddle")
    }

    // MARK: - Google Calendar (Track-6 P4)

    func testMapGoogleCalendarEventObservedReturnsEntryWithSummaryAsPrimary() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_event_observed","summary":"Sprint planning"}"#
        let entry = ActivityFeedMapper.map(
            id: 50, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .googleCalendar)
        XCTAssertEqual(entry?.eventKind, "google_calendar_event_observed")
        XCTAssertEqual(entry?.primaryText, "Sprint planning")
        XCTAssertNil(entry?.secondaryText)
    }

    func testMapGoogleCalendarEventObservedFallsBackToGenericTitleWhenSummaryMissing() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_event_observed"}"#
        let entry = ActivityFeedMapper.map(
            id: 51, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Calendar event")
    }

    func testMapGoogleCalendarEventObservedShowsAttendeesCountInSecondary() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_event_observed","summary":"Team sync","attendees_count":"5"}"#
        let entry = ActivityFeedMapper.map(
            id: 52, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Team sync")
        XCTAssertEqual(entry?.secondaryText, "5 attendees")
    }

    func testMapGoogleCalendarEventObservedSingleAttendeeUsesSingularLabel() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_event_observed","summary":"1:1","attendees_count":"1"}"#
        let entry = ActivityFeedMapper.map(
            id: 53, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.secondaryText, "1 attendee")
    }

    func testMapGoogleCalendarEventObservedAppendsVideoCallHint() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_event_observed","summary":"Standup","attendees_count":"3","conference_entry_point_type":"video"}"#
        let entry = ActivityFeedMapper.map(
            id: 54, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.secondaryText, "3 attendees · video call")
    }

    func testMapGoogleCalendarFocusBlockStartedReturnsEntry() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_focus_block_started","chat_status":"doNotDisturb"}"#
        let entry = ActivityFeedMapper.map(
            id: 55, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .googleCalendar)
        XCTAssertEqual(entry?.primaryText, "Focus block started")
        XCTAssertEqual(entry?.secondaryText, "Do not disturb")
    }

    func testMapGoogleCalendarFocusBlockEndedReturnsEntry() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_focus_block_ended"}"#
        let entry = ActivityFeedMapper.map(
            id: 56, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Focus block ended")
        XCTAssertNil(entry?.secondaryText)
    }

    func testMapGoogleCalendarOOOStartedReturnsEntry() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_ooo_started"}"#
        let entry = ActivityFeedMapper.map(
            id: 57, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Out of office started")
    }

    func testMapGoogleCalendarOOOEndedReturnsEntry() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_ooo_ended"}"#
        let entry = ActivityFeedMapper.map(
            id: 58, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Out of office ended")
    }

    func testMapGoogleCalendarWorkingLocationChangedHomeOfficeBucket() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_working_location_changed","working_location_type":"homeOffice"}"#
        let entry = ActivityFeedMapper.map(
            id: 59, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Working from home")
    }

    func testMapGoogleCalendarWorkingLocationChangedOfficeLocationBucket() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_working_location_changed","working_location_type":"officeLocation"}"#
        let entry = ActivityFeedMapper.map(
            id: 60, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Working from office")
    }

    func testMapGoogleCalendarWorkingLocationChangedCustomLocationBucket() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_working_location_changed","working_location_type":"customLocation"}"#
        let entry = ActivityFeedMapper.map(
            id: 61, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Working from custom location")
    }

    func testMapGoogleCalendarRejectsUnknownEventKind() {
        let payload = #"{"source":"google_calendar","event_kind":"google_calendar_made_up"}"#
        XCTAssertNil(ActivityFeedMapper.map(
            id: 62, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        ))
    }

    /// ADR-010 sentinel — mapper MUST NOT surface `description` / `location` /
    /// attendee `email` / `decline_message` / `conference_uri` / building
    /// labels even if a future regression stored them in the payload. The
    /// collector is the first line of defence (these keys aren't emitted);
    /// this test is the second line of defence at the mapper boundary.
    func testGoogleCalendarMapperDropsForbiddenPayloadFields() {
        let payload = """
        {"source":"google_calendar",
         "event_kind":"google_calendar_event_observed",
         "summary":"Real title",
         "description":"SECRET-DESC-XYZ",
         "location":"SECRET-LOC-XYZ",
         "attendee_email":"SECRET-EMAIL-XYZ",
         "decline_message":"SECRET-DECLINE-XYZ",
         "conference_uri":"https://meet.google.com/SECRET-URI-XYZ",
         "building_id":"SECRET-BLDG-XYZ"}
        """
        let entry = ActivityFeedMapper.map(
            id: 63, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        )
        let combined = (entry?.primaryText ?? "") + " " + (entry?.secondaryText ?? "")
        for sentinel in ["SECRET-DESC-XYZ", "SECRET-LOC-XYZ", "SECRET-EMAIL-XYZ",
                         "SECRET-DECLINE-XYZ", "SECRET-URI-XYZ", "SECRET-BLDG-XYZ"] {
            XCTAssertFalse(combined.contains(sentinel),
                           "Mapper leaked forbidden payload sentinel \(sentinel) into row text")
        }
        XCTAssertEqual(entry?.primaryText, "Real title")
    }

    // MARK: - Pulse / state filtering

    func testSkipsLinearWorkloadPulse() {
        let payload = #"{"source":"linear","event_kind":"linear_assigned_workload_pulse","started_count":"4","top_priority":"high"}"#
        XCTAssertNil(ActivityFeedMapper.map(
            id: 40, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        ))
    }

    func testSkipsGitHubNotificationsPulse() {
        let payload = #"{"source":"github","event_kind":"gh_notifications_pulse","total_unread":"7"}"#
        XCTAssertNil(ActivityFeedMapper.map(
            id: 41, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        ))
    }

    func testSkipsSlackPresenceState() {
        let payload = #"{"source":"slack","event_kind":"slack_presence_state","state":"active"}"#
        XCTAssertNil(ActivityFeedMapper.map(
            id: 42, timestampMs: ts, signalType: "context", bundleID: nil, payloadJSON: payload
        ))
    }

    // MARK: - ADR-010 sentinel-injection regression

    /// If a future collector ever stores an arbitrary body/description text in
    /// payload, the mapper must NOT surface it. Sentinel walks every payload
    /// shape across all three providers + attention.
    func testSentinelNotLeakedByMapper() {
        let sentinel = "SHOULD_NOT_LEAK_ADR010_BODY"
        // Linear status_transition with an extra `body` field.
        let linearPayload = """
        {"source":"linear","event_kind":"status_transition","issue_key":"ENG-1","to_state_name":"Done","body":"\(sentinel)","description":"\(sentinel)","comment_text":"\(sentinel)"}
        """
        let linear = ActivityFeedMapper.map(
            id: 50, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: linearPayload
        )
        XCTAssertNotNil(linear)
        XCTAssertFalse(linear!.primaryText.contains(sentinel))
        XCTAssertFalse(linear!.secondaryText?.contains(sentinel) ?? false)

        // GitHub generic event with body field.
        let githubPayload = """
        {"source":"github","event_kind":"gh_pr_opened","repo":"r/x","number":"1","body":"\(sentinel)","title":"\(sentinel)"}
        """
        let github = ActivityFeedMapper.map(
            id: 51, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: githubPayload
        )
        XCTAssertNotNil(github)
        XCTAssertFalse(github!.primaryText.contains(sentinel))
        XCTAssertFalse(github!.secondaryText?.contains(sentinel) ?? false)

        // Slack message aggregate with text field.
        let slackPayload = """
        {"source":"slack","event_kind":"slack_message_authored_aggregate","channel_name":"eng","count":"1","text":"\(sentinel)","preview":"\(sentinel)","message_text":"\(sentinel)"}
        """
        let slack = ActivityFeedMapper.map(
            id: 52, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: slackPayload
        )
        XCTAssertNotNil(slack)
        XCTAssertFalse(slack!.primaryText.contains(sentinel))
        XCTAssertFalse(slack!.secondaryText?.contains(sentinel) ?? false)

        // Attention row with stray fields.
        let attentionPayload = """
        {"foo":"\(sentinel)","note":"\(sentinel)"}
        """
        let attention = ActivityFeedMapper.map(
            id: 53, timestampMs: ts, signalType: "attention", bundleID: "com.apple.Safari",
            payloadJSON: attentionPayload
        )
        XCTAssertNotNil(attention)
        XCTAssertFalse(attention!.primaryText.contains(sentinel))
        XCTAssertFalse(attention!.secondaryText?.contains(sentinel) ?? false)
    }

    // MARK: - Robustness

    func testReturnsNilOnMalformedJSON() {
        XCTAssertNil(ActivityFeedMapper.map(
            id: 60, timestampMs: ts, signalType: "action", bundleID: nil, payloadJSON: "{not-json"
        ))
    }

    func testEmptyPayloadIsAllowedForAttention() {
        let entry = ActivityFeedMapper.map(
            id: 61, timestampMs: ts, signalType: "attention", bundleID: "com.apple.Terminal", payloadJSON: ""
        )
        XCTAssertEqual(entry?.bundleID, "com.apple.Terminal")
    }

    func testLongFieldsAreTruncated() {
        let longTitle = String(repeating: "a", count: 500)
        let entry = ActivityFeedMapper.map(
            id: 62, timestampMs: ts, signalType: "attention", bundleID: "com.foo",
            payloadJSON: #"{"window_title":"\#(longTitle)"}"#
        )
        XCTAssertNotNil(entry)
        XCTAssertLessThanOrEqual(entry!.primaryText.count, 201)
    }

    // MARK: - AI collaboration (ClaudeCodeJSONLParser shape)

    func testMapsAIToolUseWithFilePath() {
        let payload = #"{"event_kind":"tool_use","tool_name":"Edit","file_path":"/Users/me/proj/src/Foo.swift","cwd":"/Users/me/proj"}"#
        let entry = ActivityFeedMapper.map(
            id: 70, timestampMs: ts, signalType: "aiCollaboration", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.provider, .ai)
        XCTAssertEqual(entry?.eventKind, "tool_use")
        XCTAssertEqual(entry?.primaryText, "Edit")
        XCTAssertEqual(entry?.secondaryText, "Foo.swift")
    }

    func testMapsAIToolUseWithoutFilePathFallsBackToCwd() {
        let payload = #"{"event_kind":"tool_use","tool_name":"Bash","cwd":"/Users/me/some-repo"}"#
        let entry = ActivityFeedMapper.map(
            id: 71, timestampMs: ts, signalType: "aiCollaboration", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Bash")
        XCTAssertEqual(entry?.secondaryText, "some-repo")
    }

    func testMapsAIUserPromptShowsCwdOnly() {
        let payload = #"{"event_kind":"user_prompt","cwd":"/Users/me/leaf"}"#
        let entry = ActivityFeedMapper.map(
            id: 72, timestampMs: ts, signalType: "aiCollaboration", bundleID: nil, payloadJSON: payload
        )
        XCTAssertEqual(entry?.primaryText, "Prompt")
        XCTAssertEqual(entry?.secondaryText, "leaf")
    }
}

// MARK: - coalesceConsecutive

final class ActivityFeedEntryCoalesceTests: XCTestCase {

    private let baseTs = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: Int64, kind: String, primary: String, bundleID: String? = nil, addingSeconds: TimeInterval = 0) -> ActivityFeedEntry {
        ActivityFeedEntry(
            id: id,
            timestamp: baseTs.addingTimeInterval(addingSeconds),
            provider: .ai,
            eventKind: kind,
            primaryText: primary,
            secondaryText: nil,
            bundleID: bundleID
        )
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(ActivityFeedEntry.coalesceConsecutive([]).isEmpty)
    }

    func testSingleEntryPassesThrough() {
        let result = ActivityFeedEntry.coalesceConsecutive([entry(1, kind: "tool_use", primary: "Bash")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.mergedCount, 1)
    }

    func testTwoConsecutiveDuplicatesMerge() {
        let a = entry(1, kind: "tool_use", primary: "Bash", addingSeconds: 0)
        let b = entry(2, kind: "tool_use", primary: "Bash", addingSeconds: 5)
        let result = ActivityFeedEntry.coalesceConsecutive([a, b])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.mergedCount, 2)
        // Latest timestamp survives.
        XCTAssertEqual(result.first?.timestamp, b.timestamp)
    }

    func testNonConsecutiveDuplicatesDoNotMerge() {
        // A, B, A — two A entries are NOT adjacent, so no merge.
        let a1 = entry(1, kind: "tool_use", primary: "Bash", addingSeconds: 0)
        let b  = entry(2, kind: "tool_use", primary: "Read", addingSeconds: 1)
        let a2 = entry(3, kind: "tool_use", primary: "Bash", addingSeconds: 2)
        let result = ActivityFeedEntry.coalesceConsecutive([a1, b, a2])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.mergedCount), [1, 1, 1])
    }

    func testDifferentBundleIDsDoNotMergeEvenWithSameText() {
        let local1 = ActivityFeedEntry(
            id: 1, timestamp: baseTs, provider: .local,
            eventKind: "app_active", primaryText: "Safari",
            secondaryText: nil, bundleID: "com.apple.Safari"
        )
        let local2 = ActivityFeedEntry(
            id: 2, timestamp: baseTs.addingTimeInterval(1), provider: .local,
            eventKind: "app_active", primaryText: "Safari",
            secondaryText: nil, bundleID: "com.brave.Safari"  // different bundle
        )
        let result = ActivityFeedEntry.coalesceConsecutive([local1, local2])
        XCTAssertEqual(result.count, 2)
    }

    func testRunOfThreeMergesIntoOne() {
        let entries = (0..<3).map { i in
            entry(Int64(i + 1), kind: "tool_use", primary: "Bash", addingSeconds: TimeInterval(i))
        }
        let result = ActivityFeedEntry.coalesceConsecutive(entries)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.mergedCount, 3)
    }
}
