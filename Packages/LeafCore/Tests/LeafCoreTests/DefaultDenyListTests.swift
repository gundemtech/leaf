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

    func testFragmentInNonPathyField_NoMatch() {
        // I3 Stage 6 review fix — non-pathy fields are no longer scanned.
        // A commit message mentioning `.env` is legitimate (e.g.
        // "chore: improve .env.example") and must NOT be dropped.
        XCTAssertFalse(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["commit_message_subject": "chore: improve .env handling"]
        ))
    }

    func testFragmentInPathyField_Match() {
        // Scanned: file_paths_json, branch, target_ref, ref_name, repo_full_name.
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["file_paths_json": "[\"src/Foo.swift\",\"home/.env\"]"]
        ))
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_branch_created",
            payload: ["ref_name": "feature/.aws/credentials-rotation"]
        ))
    }

    func testEmptyPayload_NoMatch() {
        XCTAssertFalse(denyList.matches(eventKind: "issue_updated", payload: [:]))
    }
}
