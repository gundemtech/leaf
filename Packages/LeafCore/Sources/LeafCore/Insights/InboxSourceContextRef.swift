import Foundation

/// Typed opaque-ref dispatch surface for `InboxSourceURLDeriver`.
///
/// Associated values are opaque refs only (slug / key / number / opaque ID / sanitized path) —
/// never body / title / comment text / email subject / note content. Per ADR-010, sentinel-injection
/// regression tests assert no body bytes reach URL synthesis.
public enum InboxSourceContextRef: Equatable, Sendable {
    case linearIssue(workspaceSlug: String, key: String)
    case githubPR(owner: String, repo: String, number: Int)
    case githubIssue(owner: String, repo: String, number: Int)
    case githubPRComment(owner: String, repo: String, number: Int, commentID: Int64)
    case githubIssueComment(owner: String, repo: String, number: Int, commentID: Int64)
    case githubNotificationsRoot
    case slackThread(teamID: String, channelID: String, ts: String)
    case slackChannel(teamID: String, channelID: String)
    case calendarEvent(eventID: String)
    case zoomMeeting(meetingID: String)
    case xcodeBuild(projectIdentifier: String?)
    case mailMailbox(accountID: String, mailboxID: String)
    case reminderList(listID: String)
}
