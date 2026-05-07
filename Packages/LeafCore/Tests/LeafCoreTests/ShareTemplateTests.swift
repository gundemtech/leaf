import XCTest
@testable import LeafCore

final class ShareTemplateTests: XCTestCase {
    func testAskToJoin_BodyContainsOrgName() {
        let body = ShareTemplate.compose(.askToJoin(orgName: "Acme"))
        XCTAssertTrue(body.contains("Acme"), "body must mention orgName")
        XCTAssertTrue(body.contains("Join existing team"), "body must reference onboarding CTA")
    }

    func testInviteeShare_BodyContainsDisplayNameAndJoinCode() {
        let body = ShareTemplate.compose(.inviteeShare(displayName: "Anton", joinCode: "ABCD-EFGH"))
        XCTAssertTrue(body.contains("Anton"))
        XCTAssertTrue(body.contains("ABCD-EFGH"))
    }

    func testAdminShare_BodyContainsURLAndDisplayName() {
        let url = URL(string: "leaf://invite/ABC#123456")!
        let body = ShareTemplate.compose(.adminShare(displayName: "Anton", inviteURL: url))
        XCTAssertTrue(body.contains("Anton"))
        XCTAssertTrue(body.contains("leaf://invite/ABC#123456"))
        XCTAssertTrue(body.contains("24"), "must mention 24h expiry")
    }

    func testMailtoURL_PercentEncodesBody() throws {
        let mailto = ShareTemplate.mailtoURL(subject: "Leaf invite", body: "Привет\nABCD-EFGH")
        XCTAssertEqual(mailto.scheme, "mailto")
        let abs = mailto.absoluteString
        XCTAssertTrue(abs.contains("subject="))
        XCTAssertTrue(abs.contains("body="))
        // Cyrillic char must be percent-encoded.
        XCTAssertFalse(abs.contains("Привет"))
        // Newline encoded as %0A.
        XCTAssertTrue(abs.contains("%0A"))
    }

    func testSmsURL_PercentEncodesBody() throws {
        let sms = ShareTemplate.smsURL(body: "Hey\nLeaf")
        XCTAssertEqual(sms.scheme, "sms")
        XCTAssertTrue(sms.absoluteString.contains("body="))
        XCTAssertTrue(sms.absoluteString.contains("%0A"))
    }

    func testEmojiAndUnicodeInDisplayName_DoesNotCorruptMailto() {
        let body = ShareTemplate.compose(.inviteeShare(displayName: "Аня 🌿", joinCode: "X-Y"))
        let mailto = ShareTemplate.mailtoURL(subject: "S", body: body)
        XCTAssertNotNil(URL(string: mailto.absoluteString), "mailto URL must remain parseable")
        XCTAssertTrue(mailto.absoluteString.contains("body="))
    }
}
