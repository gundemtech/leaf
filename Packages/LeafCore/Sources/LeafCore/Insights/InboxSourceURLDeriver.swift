import Foundation

/// Universal URL synthesizer for INBOX rows.
///
/// Pure-function dispatch from typed opaque refs to deep-link URLs. No DB access, no async,
/// no actor-bound state. Empty/zero refs degrade gracefully to `nil` (caller renders disabled row).
public enum InboxSourceURLDeriver {

    public static func synthesize(_ ref: InboxSourceContextRef) -> URL? {
        switch ref {
        case .linearIssue(let slug, let key):
            guard !slug.isEmpty, !key.isEmpty else { return nil }
            return URL(string: "https://linear.app/\(slug)/issue/\(key)")

        case .githubPR(let owner, let repo, let number):
            guard !owner.isEmpty, !repo.isEmpty, number > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")

        case .githubIssue(let owner, let repo, let number):
            guard !owner.isEmpty, !repo.isEmpty, number > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)")

        case .githubPRComment(let owner, let repo, let number, let commentID):
            guard !owner.isEmpty, !repo.isEmpty, number > 0, commentID > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)#discussion_r\(commentID)")

        case .githubIssueComment(let owner, let repo, let number, let commentID):
            guard !owner.isEmpty, !repo.isEmpty, number > 0, commentID > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)#issuecomment-\(commentID)")

        case .githubNotificationsRoot:
            return URL(string: "https://github.com/notifications")

        case .slackThread(let teamID, let channelID, let ts):
            guard !teamID.isEmpty, !channelID.isEmpty, !ts.isEmpty else { return nil }
            return URL(string: "slack://channel?team=\(teamID)&id=\(channelID)&message=\(ts)")

        case .slackChannel(let teamID, let channelID):
            guard !teamID.isEmpty, !channelID.isEmpty else { return nil }
            return URL(string: "slack://channel?team=\(teamID)&id=\(channelID)")

        case .calendarEvent(let eventID):
            guard !eventID.isEmpty else { return nil }
            return URL(string: "ical://\(eventID)")

        case .zoomMeeting(let meetingID):
            guard !meetingID.isEmpty else { return nil }
            return URL(string: "zoommtg://zoom.us/join?confno=\(meetingID)")

        case .xcodeBuild(let projectPath):
            guard let path = projectPath, !path.isEmpty else { return nil }
            return URL(string: "xcode://\(path)")

        case .mailMailbox(let accountID, let mailboxID):
            guard !accountID.isEmpty, !mailboxID.isEmpty else { return nil }
            return URL(string: "message://%3C\(accountID)/\(mailboxID)%3E")

        case .reminderList(let listID):
            guard !listID.isEmpty else { return nil }
            return URL(string: "x-apple-reminderkit://REMCDReminder/\(listID)")
        }
    }
}
