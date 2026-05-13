import XCTest
@testable import LeafCore

final class TeamKeystoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LeafTeamKeystoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - X25519 private — round-trip + permissions + atomic overwrite

    func testWriteAndReadX25519Private_RoundTrip() throws {
        let bytes = Data((0..<32).map { UInt8($0) })

        try TeamKeystore.writeX25519Private(bytes, at: tempRoot)
        let readBack = try TeamKeystore.readX25519Private(at: tempRoot)

        XCTAssertEqual(readBack, bytes)
    }

    func testWriteX25519Private_AppliesPosix0600() throws {
        let bytes = Data(repeating: 0xAA, count: 32)
        try TeamKeystore.writeX25519Private(bytes, at: tempRoot)

        let path = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename).path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1

        XCTAssertEqual(perm & 0o777, 0o600, "expected 0o600, got \(String(perm, radix: 8))")
    }

    func testWriteX25519Private_AtomicOverwrite() throws {
        let first = Data(repeating: 0x11, count: 32)
        let second = Data(repeating: 0x22, count: 32)

        try TeamKeystore.writeX25519Private(first, at: tempRoot)
        try TeamKeystore.writeX25519Private(second, at: tempRoot)

        let readBack = try TeamKeystore.readX25519Private(at: tempRoot)
        XCTAssertEqual(readBack, second)

        // Permissions survive atomic rename (rename creates new inode).
        let path = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename).path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perm & 0o777, 0o600)
    }

    // MARK: - TeamKey (workspace-scoped) — round-trip + permissions

    func testWriteAndReadTeamKey_Workspace_RoundTrip() throws {
        let workspaceID = UUID().uuidString.lowercased()
        let keyID = UUID().uuidString.lowercased()
        let bytes = Data((0..<32).map { UInt8($0 ^ 0x55) })

        try TeamKeystore.writeTeamKey(bytes, workspaceID: workspaceID, keyID: keyID, at: tempRoot)
        let readBack = try TeamKeystore.readTeamKey(workspaceID: workspaceID, keyID: keyID, at: tempRoot)

        XCTAssertEqual(readBack, bytes)
    }

    func testReadTeamKey_Workspace_UnknownID_Throws() {
        let workspaceID = UUID().uuidString.lowercased()
        let keyID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(
            try TeamKeystore.readTeamKey(workspaceID: workspaceID, keyID: keyID, at: tempRoot)
        ) { error in
            XCTAssertTrue(isKeyFileUnavailable(error), "got: \(error)")
        }
    }

    // MARK: - Error paths

    func testReadX25519Private_Corrupted_Throws() throws {
        // Write 31 bytes raw via Data.write (bypass keystore length validation).
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let path = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename)
        try Data(repeating: 0x00, count: 31).write(to: path)

        XCTAssertThrowsError(try TeamKeystore.readX25519Private(at: tempRoot)) { error in
            XCTAssertTrue(isKeyFileCorrupted(error), "got: \(error)")
        }
    }

    // MARK: - Helpers

    private func isKeyFileUnavailable(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        if case .keyFileUnavailable = leafErr { return true }
        return false
    }

    private func isKeyFileCorrupted(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        if case .keyFileCorrupted = leafErr { return true }
        return false
    }
}
