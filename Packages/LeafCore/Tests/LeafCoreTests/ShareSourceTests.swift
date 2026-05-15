// Phase Track-5 S5 — ShareSource enum + ShareRuleDefaults invariants.

import XCTest
@testable import LeafCore

final class ShareSourceTests: XCTestCase {

    func testEnumHasExactlyNineCasesPerContractSection11() {
        XCTAssertEqual(ShareSource.allCases.count, 9)
    }

    func testRawValuesAreStableSnakeCase() {
        XCTAssertEqual(ShareSource.gitCommits.rawValue,            "git_commits")
        XCTAssertEqual(ShareSource.linearIssues.rawValue,          "linear_issues")
        XCTAssertEqual(ShareSource.slackMentions.rawValue,         "slack_mentions")
        XCTAssertEqual(ShareSource.githubPRs.rawValue,             "github_prs")
        XCTAssertEqual(ShareSource.detectedDecisions.rawValue,     "detected_decisions")
        XCTAssertEqual(ShareSource.detectedBlockers.rawValue,      "detected_blockers")
        XCTAssertEqual(ShareSource.detectedOpenQuestions.rawValue, "detected_open_questions")
        XCTAssertEqual(ShareSource.detectedWhereStopped.rawValue,  "detected_where_stopped")
        XCTAssertEqual(ShareSource.rawGitHubActivity.rawValue,     "raw_github_activity")
    }

    func testSchemaShareSourcesMirrorEnumRawValues() {
        XCTAssertEqual(Schema.ShareSources.gitCommits,            ShareSource.gitCommits.rawValue)
        XCTAssertEqual(Schema.ShareSources.linearIssues,          ShareSource.linearIssues.rawValue)
        XCTAssertEqual(Schema.ShareSources.slackMentions,         ShareSource.slackMentions.rawValue)
        XCTAssertEqual(Schema.ShareSources.githubPRs,             ShareSource.githubPRs.rawValue)
        XCTAssertEqual(Schema.ShareSources.detectedDecisions,     ShareSource.detectedDecisions.rawValue)
        XCTAssertEqual(Schema.ShareSources.detectedBlockers,      ShareSource.detectedBlockers.rawValue)
        XCTAssertEqual(Schema.ShareSources.detectedOpenQuestions, ShareSource.detectedOpenQuestions.rawValue)
        XCTAssertEqual(Schema.ShareSources.detectedWhereStopped,  ShareSource.detectedWhereStopped.rawValue)
        XCTAssertEqual(Schema.ShareSources.rawGitHubActivity,     ShareSource.rawGitHubActivity.rawValue)
    }

    func testDefaultsONForOutcomeBearingSources() {
        XCTAssertTrue(ShareRuleDefaults.isEnabledByDefault(.gitCommits))
        XCTAssertTrue(ShareRuleDefaults.isEnabledByDefault(.linearIssues))
        XCTAssertTrue(ShareRuleDefaults.isEnabledByDefault(.detectedDecisions))
        XCTAssertTrue(ShareRuleDefaults.isEnabledByDefault(.detectedBlockers))
    }

    func testDefaultsOFFForPrivacy() {
        XCTAssertFalse(ShareRuleDefaults.isEnabledByDefault(.slackMentions))
        XCTAssertFalse(ShareRuleDefaults.isEnabledByDefault(.githubPRs))
        XCTAssertFalse(ShareRuleDefaults.isEnabledByDefault(.detectedOpenQuestions))
        XCTAssertFalse(ShareRuleDefaults.isEnabledByDefault(.detectedWhereStopped))
        XCTAssertFalse(ShareRuleDefaults.isEnabledByDefault(.rawGitHubActivity))
    }

    func testDefaultsTableCoversEveryCase() {
        for source in ShareSource.allCases {
            XCTAssertNotNil(ShareRuleDefaults.all[source], "source \(source.rawValue) missing default")
        }
    }

    func testShareRuleInitAssignsAllFields() {
        let r = ShareRule(workspaceID: "wid1", source: .gitCommits, enabled: true, updatedAtMs: 5_000)
        XCTAssertEqual(r.workspaceID, "wid1")
        XCTAssertEqual(r.source, .gitCommits)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.updatedAtMs, 5_000)
    }
}
