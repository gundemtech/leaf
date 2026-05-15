// Phase Track-5 S5 — DefaultDenyList rules invariants.

import XCTest
@testable import LeafCore

final class DefaultDenyListTests: XCTestCase {
    private let denyList = DefaultDenyList()

    func testEnvPath_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_path": "/home/.env"]))
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_path": "/home/work/.env.local"]))
    }

    func testGitConfigPath_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_path": "/repo/.git/config"]))
    }

    func testAWSCredentialsPath_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_path": "/home/.aws/credentials"]))
    }

    func testSSHPath_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_path": "/home/.ssh/id_rsa"]))
    }

    func testLargeFile_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_size": "200000000"]))
    }

    func testFileSizeBelowCap_NoMatch() {
        XCTAssertFalse(denyList.matches(eventKind: "gh_commit_pushed", payload: ["file_size": "99999999"]))
    }

    func testAIPrefixKind_Match() {
        XCTAssertTrue(denyList.matches(eventKind: "ai_prompt_submitted", payload: [:]))
    }

    func testCleanEvent_NoMatch() {
        XCTAssertFalse(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["file_path": "/repo/src/Main.swift", "file_size": "12000"]
        ))
    }

    func testFragmentInArbitraryField_Match() {
        // Any string field containing a banned fragment must match — not just
        // file_path. Defends against future collectors emitting under different
        // payload keys.
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["random_field": "trace: opening .env to load secret"]
        ))
    }

    func testEmptyPayload_NoMatch() {
        XCTAssertFalse(denyList.matches(eventKind: "issue_updated", payload: [:]))
    }
}
