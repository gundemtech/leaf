import Foundation

/// File-backed BYOK key store (Track AI Coworker P1). The BYOK Anthropic key
/// lives at the keystore root (`~/Library/Application Support/Leaf/keystore/`)
/// as a 0600 raw-UTF-8 file, mirroring `SupabaseSessionStore`/`FileKeyStore`.
///
/// Rationale (user-chosen, plan §4/H-6): the read-only MCP process needs the key
/// but cannot read the app's Keychain (no shared access group — the project
/// already moved cross-process keys off Keychain to files in Phase 3.4.5). The
/// file sits beside `supabase-session.json` / `db.key` / `x25519.priv` at the
/// same 0600 + FileVault confidentiality bar. The key is NEVER logged.
///
/// `loadKey()` returns `nil` on a missing/empty file (→ `.missingAPIKey` at the
/// summarizer — a clean tool error, not a crash); it throws only on a genuine
/// IO / decode failure.
public struct FileAnthropicKeyStore: AnthropicKeyStore {
  public static let filename = "anthropic-byok.key"

  private let path: URL

  public init(at keystoreRoot: URL = TeamKeystore.defaultRoot()) {
    self.path = keystoreRoot.appendingPathComponent(Self.filename, isDirectory: false)
  }

  public func loadKey() throws -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: path)
    } catch {
      throw LeafError.keyFileUnavailable(reason: "byok key read failed")
    }
    guard let raw = String(data: data, encoding: .utf8) else {
      throw LeafError.keyFileCorrupted
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
  }

  public func storeKey(_ key: String) throws {
    try ensureDirectoryExists()
    do {
      try Data(key.utf8).write(to: path, options: [.atomic])
    } catch {
      throw LeafError.keyFileUnavailable(reason: "byok key write failed")
    }
    try setStrictPermissions()
  }

  public func deleteKey() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path.path) else { return }
    do {
      try fm.removeItem(at: path)
    } catch {
      throw LeafError.keyFileUnavailable(reason: "byok key delete failed")
    }
  }

  // MARK: - Internal

  private func ensureDirectoryExists() throws {
    let fm = FileManager.default
    let dir = path.deletingLastPathComponent()
    var isDir: ObjCBool = false
    if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
      do {
        try fm.createDirectory(
          at: dir, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw LeafError.keyFileUnavailable(reason: "byok keystore mkdir failed")
      }
    }
  }

  private func setStrictPermissions() throws {
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: path.path)
    } catch {
      throw LeafError.keyFileUnavailable(reason: "byok key chmod failed")
    }
  }
}
