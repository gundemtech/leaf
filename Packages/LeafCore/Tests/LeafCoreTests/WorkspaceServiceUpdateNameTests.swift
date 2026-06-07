// Track 5 / S7 E.1 — WorkspaceService.updateName unit tests.
// TDD: tests written before implementation.

import XCTest
import CryptoKit
@testable import LeafCore

final class WorkspaceServiceUpdateNameTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var db: Database!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-update-\(UUID().uuidString)")
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try! Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService() -> WorkspaceService {
        WorkspaceService(
            database: db,
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            randomBytes: { count in Data(repeating: 0x42, count: count) },
            randomUUID: { UUID().uuidString.lowercased() }
        )
    }

    // MARK: - Creator display name

    /// Regression — the creator's TeamMember.displayName must be the creator's
    /// PERSONAL name, not the workspace name. Otherwise a joiner sees the admin
    /// labelled as the team (e.g. "test-2") instead of a person.
    func testCreateWorkspace_CreatorDisplayName_DistinctFromWorkspaceName() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme Corp", creatorDisplayName: "Alex Rivera")
        XCTAssertEqual(ws.name, "Acme Corp")
        let members = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: false)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(
            members.first?.displayName, "Alex Rivera",
            "creator's member displayName must be their personal name, not the workspace name"
        )
    }

    /// Omitting creatorDisplayName preserves the legacy fallback (workspace name)
    /// so existing callers/tests are unaffected.
    func testCreateWorkspace_NoCreatorName_FallsBackToWorkspaceName() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Solo Team")
        let members = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: false)
        XCTAssertEqual(members.first?.displayName, "Solo Team")
    }

    // MARK: - Validation

    func testUpdateName_Empty_ThrowsInvalidPayload() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        XCTAssertThrowsError(try svc.updateName(workspaceID: ws.id, newName: "")) { err in
            XCTAssertEqual(err as? LeafError, LeafError.invalidPayload)
        }
    }

    func testUpdateName_WhitespaceOnly_ThrowsInvalidPayload() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        XCTAssertThrowsError(try svc.updateName(workspaceID: ws.id, newName: "   ")) { err in
            XCTAssertEqual(err as? LeafError, LeafError.invalidPayload)
        }
    }

    func testUpdateName_TooLong_ThrowsInvalidPayload() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        let longName = String(repeating: "x", count: 81)
        XCTAssertThrowsError(try svc.updateName(workspaceID: ws.id, newName: longName)) { err in
            XCTAssertEqual(err as? LeafError, LeafError.invalidPayload)
        }
    }

    // MARK: - Success

    func testUpdateName_Success_UpdatesLocalRow() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        try svc.updateName(workspaceID: ws.id, newName: "Renamed")
        let updated = try db.readWorkspace(id: ws.id)
        XCTAssertEqual(updated?.name, "Renamed")
    }

    func testUpdateName_TrimsLeadingTrailingWhitespace() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        try svc.updateName(workspaceID: ws.id, newName: "  Trimmed  ")
        let updated = try db.readWorkspace(id: ws.id)
        XCTAssertEqual(updated?.name, "Trimmed")
    }

    func testUpdateName_Exactly80Chars_Succeeds() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Original")
        let name80 = String(repeating: "a", count: 80)
        XCTAssertNoThrow(try svc.updateName(workspaceID: ws.id, newName: name80))
        let updated = try db.readWorkspace(id: ws.id)
        XCTAssertEqual(updated?.name, name80)
    }

    func testUpdateName_NonexistentWorkspace_NoErrorButNoUpdate() throws {
        let svc = makeService()
        // Unknown workspace ID — UPDATE WHERE id=? matches 0 rows, no error.
        XCTAssertNoThrow(try svc.updateName(workspaceID: "nonexistent-id", newName: "New"))
    }
}
