// Phase Track-5 S5 — ShareRulesStore CRUD invariants.

import XCTest
import GRDB
@testable import LeafCore

final class ShareRulesStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-share-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadEffective_AbsentRowsFallBackToDefaults() throws {
        let map = try db.writeSQL { rawDB in
            try ShareRulesStore.readEffective(workspaceID: "wid", in: rawDB)
        }
        XCTAssertTrue(map[.gitCommits] ?? false)            // ON by default
        XCTAssertTrue(map[.linearIssues] ?? false)          // ON by default
        XCTAssertTrue(map[.detectedDecisions] ?? false)
        XCTAssertTrue(map[.detectedBlockers] ?? false)
        XCTAssertFalse(map[.slackMentions] ?? true)         // OFF by default
        XCTAssertFalse(map[.githubPRs] ?? true)
        XCTAssertFalse(map[.detectedOpenQuestions] ?? true)
        XCTAssertFalse(map[.detectedWhereStopped] ?? true)
        XCTAssertFalse(map[.rawGitHubActivity] ?? true)
        XCTAssertEqual(map.count, 9)
    }

    func testUpsert_OverridesDefault_AndIsIdempotent() throws {
        try db.writeSQL { rawDB in
            // Persist ON for slackMentions (default OFF) and OFF for gitCommits (default ON).
            try ShareRulesStore.upsert(workspaceID: "wid", source: .slackMentions, enabled: true, updatedAtMs: 100, in: rawDB)
            try ShareRulesStore.upsert(workspaceID: "wid", source: .gitCommits, enabled: false, updatedAtMs: 200, in: rawDB)
        }

        let map = try db.writeSQL { rawDB in
            try ShareRulesStore.readEffective(workspaceID: "wid", in: rawDB)
        }
        XCTAssertTrue(map[.slackMentions] ?? false)
        XCTAssertFalse(map[.gitCommits] ?? true)
        XCTAssertTrue(map[.linearIssues] ?? false)  // unchanged default

        // UPSERT same key with new value.
        try db.writeSQL { rawDB in
            try ShareRulesStore.upsert(workspaceID: "wid", source: .gitCommits, enabled: true, updatedAtMs: 300, in: rawDB)
        }
        let map2 = try db.writeSQL { rawDB in
            try ShareRulesStore.readEffective(workspaceID: "wid", in: rawDB)
        }
        XCTAssertTrue(map2[.gitCommits] ?? false)
    }

    func testRead_ReturnsPersistedRow() throws {
        try db.writeSQL { rawDB in
            try ShareRulesStore.upsert(workspaceID: "wid", source: .githubPRs, enabled: true, updatedAtMs: 500, in: rawDB)
        }
        let rule = try db.writeSQL { rawDB in
            try ShareRulesStore.read(workspaceID: "wid", source: .githubPRs, in: rawDB)
        }
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.workspaceID, "wid")
        XCTAssertEqual(rule?.source, .githubPRs)
        XCTAssertTrue(rule?.enabled ?? false)
        XCTAssertEqual(rule?.updatedAtMs, 500)
    }

    func testRead_NilWhenAbsent() throws {
        let rule = try db.writeSQL { rawDB in
            try ShareRulesStore.read(workspaceID: "wid", source: .rawGitHubActivity, in: rawDB)
        }
        XCTAssertNil(rule)
    }

    func testIsEnabled_PersistedOverridesDefault() throws {
        try db.writeSQL { rawDB in
            try ShareRulesStore.upsert(workspaceID: "wid", source: .gitCommits, enabled: false, updatedAtMs: 100, in: rawDB)
        }
        let enabled = try db.writeSQL { rawDB in
            try ShareRulesStore.isEnabled(workspaceID: "wid", source: .gitCommits, in: rawDB)
        }
        XCTAssertFalse(enabled)
    }

    func testMultipleWorkspaces_IsolatedRows() throws {
        try db.writeSQL { rawDB in
            try ShareRulesStore.upsert(workspaceID: "wid-a", source: .slackMentions, enabled: true, updatedAtMs: 100, in: rawDB)
            try ShareRulesStore.upsert(workspaceID: "wid-b", source: .slackMentions, enabled: false, updatedAtMs: 200, in: rawDB)
        }
        let a = try db.writeSQL { rawDB in
            try ShareRulesStore.isEnabled(workspaceID: "wid-a", source: .slackMentions, in: rawDB)
        }
        let b = try db.writeSQL { rawDB in
            try ShareRulesStore.isEnabled(workspaceID: "wid-b", source: .slackMentions, in: rawDB)
        }
        XCTAssertTrue(a)
        XCTAssertFalse(b)
    }
}
