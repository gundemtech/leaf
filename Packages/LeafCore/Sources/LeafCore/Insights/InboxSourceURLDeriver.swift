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

        case .xcodeBuild:
            // C-28 (T10): `xcode://` is a fictional URL scheme — there is no
            // registered macOS LSScheme handler for it, so `NSWorkspace.shared.open()`
            // would fail silently. Until a real Xcode deep-link mechanism lands
            // (e.g. Apple ships an `xcdeeplink://` or third-party tools register
            // a scheme), INBOX rows for xcode build events stay non-tappable
            // (`sourceURL = nil` → row renders without tap target per T8
            // baseline graceful behavior). Enum case kept (no breaking
            // surface change) — `projectIdentifier` associated value is
            // accepted but ignored. Carry post-Track-9 when real deep-link
            // mechanism becomes available.
            return nil

        case .mailMailbox(let accountID, let mailboxID):
            guard !accountID.isEmpty, !mailboxID.isEmpty else { return nil }
            return URL(string: "message://%3C\(accountID)/\(mailboxID)%3E")

        case .reminderList(let listID):
            guard !listID.isEmpty else { return nil }
            return URL(string: "x-apple-reminderkit://REMCDReminder/\(listID)")
        }
    }
}
