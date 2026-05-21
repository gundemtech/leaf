import XCTest
@testable import LeafCore

final class InboxSourceURLDeriverTests: XCTestCase {

    // MARK: - Linear

    func testLinearIssue_synthesizesCanonical() {
        let url = InboxSourceURLDeriver.synthesize(.linearIssue(workspaceSlug: "leaf", key: "LEAF-42"))
        XCTAssertEqual(url?.absoluteString, "https://linear.app/leaf/issue/LEAF-42")
    }

    func testLinearIssue_emptySlugReturnsNil() {
        let url = InboxSourceURLDeriver.synthesize(.linearIssue(workspaceSlug: "", key: "LEAF-42"))
        XCTAssertNil(url)
    }

    // MARK: - GitHub

    func testGithubPR_synthesizesCanonical() {
        let url = InboxSourceURLDeriver.synthesize(.githubPR(owner: "gundemtech", repo: "leaf", number: 142))
        XCTAssertEqual(url?.absoluteString, "https://github.com/gundemtech/leaf/pull/142")
    }

    func testGithubIssue_synthesizesCanonical() {
        let url = InboxSourceURLDeriver.synthesize(.githubIssue(owner: "gundemtech", repo: "leaf", number: 99))
        XCTAssertEqual(url?.absoluteString, "https://github.com/gundemtech/leaf/issues/99")
    }

    func testGithubPRComment_appendsDiscussionAnchor() {
        let url = InboxSourceURLDeriver.synthesize(.githubPRComment(owner: "gundemtech", repo: "leaf", number: 142, commentID: 5550001))
        XCTAssertEqual(url?.absoluteString, "https://github.com/gundemtech/leaf/pull/142#discussion_r5550001")
    }

    func testGithubIssueComment_appendsIssueCommentAnchor() {
        let url = InboxSourceURLDeriver.synthesize(.githubIssueComment(owner: "gundemtech", repo: "leaf", number: 99, commentID: 7770002))
        XCTAssertEqual(url?.absoluteString, "https://github.com/gundemtech/leaf/issues/99#issuecomment-7770002")
    }

    func testGithubNotificationsRoot_synthesizesCanonical() {
        let url = InboxSourceURLDeriver.synthesize(.githubNotificationsRoot)
        XCTAssertEqual(url?.absoluteString, "https://github.com/notifications")
    }

    // MARK: - Slack

    func testSlackThread_synthesizesDeepLink() {
        let url = InboxSourceURLDeriver.synthesize(.slackThread(teamID: "T01", channelID: "C012ABC", ts: "1700000000.001"))
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T01&id=C012ABC&message=1700000000.001")
    }

    func testSlackChannel_synthesizesDeepLink() {
        let url = InboxSourceURLDeriver.synthesize(.slackChannel(teamID: "T01", channelID: "C012ABC"))
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T01&id=C012ABC")
    }

    // MARK: - Calendar / Zoom

    func testCalendarEvent_synthesizesIcalScheme() {
        let url = InboxSourceURLDeriver.synthesize(.calendarEvent(eventID: "evt-12345"))
        XCTAssertEqual(url?.absoluteString, "ical://evt-12345")
    }

    func testZoomMeeting_synthesizesDeepLink() {
        let url = InboxSourceURLDeriver.synthesize(.zoomMeeting(meetingID: "9876543210"))
        XCTAssertEqual(url?.absoluteString, "zoommtg://zoom.us/join?confno=9876543210")
    }

    // MARK: - Xcode

    func testXcodeBuild_synthesizesCanonical() {
        let url = InboxSourceURLDeriver.synthesize(.xcodeBuild(projectPath: "/Users/dima/Desktop/Leaf/leaf"))
        XCTAssertEqual(url?.absoluteString, "xcode:///Users/dima/Desktop/Leaf/leaf")
    }

    func testXcodeBuild_returnsNilWhenProjectPathAbsent() {
        let url = InboxSourceURLDeriver.synthesize(.xcodeBuild(projectPath: nil))
        XCTAssertNil(url)
    }

    // MARK: - Mail / Reminders

    func testMailMailbox_synthesizesMessageScheme() {
        let url = InboxSourceURLDeriver.synthesize(.mailMailbox(accountID: "acct1", mailboxID: "INBOX"))
        XCTAssertEqual(url?.absoluteString, "message://%3Cacct1/INBOX%3E")
    }

    func testReminderList_synthesizesAppleReminderKitScheme() {
        let url = InboxSourceURLDeriver.synthesize(.reminderList(listID: "list-uuid-1"))
        XCTAssertEqual(url?.absoluteString, "x-apple-reminderkit://REMCDReminder/list-uuid-1")
    }

    // MARK: - ContextRef Equatable + Sendable

    func testContextRefEquatable_sameCaseEquates() {
        let a = InboxSourceContextRef.linearIssue(workspaceSlug: "leaf", key: "LEAF-42")
        let b = InboxSourceContextRef.linearIssue(workspaceSlug: "leaf", key: "LEAF-42")
        XCTAssertEqual(a, b)
    }
}
