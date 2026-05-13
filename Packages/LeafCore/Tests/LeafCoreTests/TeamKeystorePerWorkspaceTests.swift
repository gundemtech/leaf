import XCTest
@testable import LeafCore

/// Track-5 S2 — workspace-scoped TeamKeystore API surface. Asserts:
/// 1. Two workspaces write to disjoint sub-folders; cross-workspace reads miss.
/// 2. `deleteWorkspace` is scoped — sibling workspace preserved.
/// 3. `relocateLegacyTeamKeys` moves files from legacy `<root>/team-keys/<id>.key`
///    to `<root>/workspaces/<wid>/team-keys/<id>.key` and is idempotent on
///    second call.
/// 4. Files written under the workspace layout retain 0o600 POSIX permissions.
final class TeamKeystorePerWorkspaceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-ws-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testWriteRead_TwoWorkspaces_SeparateFiles() throws {
        let w1 = "ws-1-uuid"
        let w2 = "ws-2-uuid"
        let k1 = "key-1-uuid"
        let k2 = "key-2-uuid"
        let bytes1 = Data(repeating: 0xAA, count: 32)
        let bytes2 = Data(repeating: 0xBB, count: 32)

        try TeamKeystore.writeTeamKey(bytes1, workspaceID: w1, keyID: k1, at: tempRoot)
        try TeamKeystore.writeTeamKey(bytes2, workspaceID: w2, keyID: k2, at: tempRoot)

        XCTAssertEqual(try TeamKeystore.readTeamKey(workspaceID: w1, keyID: k1, at: tempRoot), bytes1)
        XCTAssertEqual(try TeamKeystore.readTeamKey(workspaceID: w2, keyID: k2, at: tempRoot), bytes2)

        // Cross-workspace read fails — file at w1/k2 path doesn't exist.
        XCTAssertThrowsError(try TeamKeystore.readTeamKey(workspaceID: w1, keyID: k2, at: tempRoot)) { err in
            guard case LeafError.keyFileUnavailable = err else {
                return XCTFail("Expected keyFileUnavailable, got \(err)")
            }
        }
    }

    func testDeleteWorkspace_RemovesOnlyThatWorkspace() throws {
        let w1 = "ws-1-uuid"
        let w2 = "ws-2-uuid"
        let key1 = "k-uuid"
        let key2 = "k-uuid2"
        try TeamKeystore.writeTeamKey(Data(repeating: 0xAA, count: 32),
                                      workspaceID: w1, keyID: key1, at: tempRoot)
        try TeamKeystore.writeTeamKey(Data(repeating: 0xBB, count: 32),
                                      workspaceID: w2, keyID: key2, at: tempRoot)

        try TeamKeystore.deleteWorkspace(workspaceID: w1, at: tempRoot)

        // w1 gone.
        XCTAssertThrowsError(try TeamKeystore.readTeamKey(workspaceID: w1, keyID: key1, at: tempRoot))
        // w2 preserved.
        XCTAssertNoThrow(try TeamKeystore.readTeamKey(workspaceID: w2, keyID: key2, at: tempRoot))
    }

    func testRelocateLegacyTeamKeys_MovesFiles_Idempotent() throws {
        // Step A — write a file at the legacy single-workspace path:
        //   <tempRoot>/team-keys/<keyID>.key
        let keyID = "legacy-key-uuid"
        let legacyURL = tempRoot
            .appendingPathComponent("team-keys", isDirectory: true)
            .appendingPathComponent("\(keyID).key", isDirectory: false)
        let bytes = Data(repeating: 0xCC, count: 32)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: legacyURL, options: [.atomic])

        let w1 = "ws-1-uuid"

        // Step B — first relocate.
        try TeamKeystore.relocateLegacyTeamKeys(toWorkspaceID: w1, at: tempRoot)

        // Step C — verify the legacy file is gone and contents survived under
        // the new path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "legacy file should be removed after relocate")
        let newReadBytes = try TeamKeystore.readTeamKey(workspaceID: w1, keyID: keyID, at: tempRoot)
        XCTAssertEqual(newReadBytes, bytes)

        // Step D — second call must be a silent no-op (idempotent path).
        XCTAssertNoThrow(try TeamKeystore.relocateLegacyTeamKeys(toWorkspaceID: w1, at: tempRoot))
        XCTAssertEqual(try TeamKeystore.readTeamKey(workspaceID: w1, keyID: keyID, at: tempRoot), bytes)
    }

    func testWriteTeamKey_FilePermissions0o600() throws {
        let w1 = "ws-x"
        let k = "k-x"
        try TeamKeystore.writeTeamKey(Data(repeating: 0x01, count: 32),
                                      workspaceID: w1, keyID: k, at: tempRoot)
        let url = tempRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(w1, isDirectory: true)
            .appendingPathComponent("team-keys", isDirectory: true)
            .appendingPathComponent("\(k).key", isDirectory: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }
}
