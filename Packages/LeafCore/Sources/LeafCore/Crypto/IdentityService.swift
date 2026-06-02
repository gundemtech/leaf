import CryptoKit
import Foundation

/// Phase 5.2.A — idempotent X25519 long-term identity bootstrap.
/// Reads `<root>/x25519.priv` if it exists (32B), otherwise generates
/// `Curve25519.KeyAgreement.PrivateKey()` + atomically writes through
/// `TeamKeystore.writeX25519Private`. Mirror enum-namespace style of
/// `TeamKeystore` (5.1.D).
///
/// Single source of truth for long-term identity bootstrap on both sides of the
/// invite handshake (admin `OrgService.createPersonalOrg` + invitee
/// accept-invite path in 5.2.E). Replaces the 5.1.D inline
/// `randomX25519PrivateKey` factory in `OrgService` (commit 4 of this phase).
public enum IdentityService {

  /// Read the existing 32B X25519 priv from `<root>/x25519.priv` if the file exists;
  /// otherwise generate a new keypair and atomically write it.
  /// - Throws:
  ///   - `LeafError.keyFileCorrupted` — the file exists, but its size ≠ 32B
  ///     (propagates, not a silent regenerate — invariant: corrupted state
  ///     stays observable).
  ///   - `LeafError.keyFileUnavailable(reason:)` — write failed
  ///     (filesystem / permissions).
  public static func ensureLocalIdentity(
    at root: URL = TeamKeystore.defaultRoot()
  ) throws -> Curve25519.KeyAgreement.PrivateKey {
    return try ensureLocalIdentity(
      at: root,
      generate: {
        Curve25519.KeyAgreement.PrivateKey()
      })
  }

  /// Test/dev overload — inject a deterministic keypair generator. Used only on
  /// the gen-path (when the file is absent). If the file is already on disk,
  /// the generator is NOT called (see `IdentityServiceTests.testInjectedGenerator_…`).
  public static func ensureLocalIdentity(
    at root: URL,
    generate: @Sendable () -> Curve25519.KeyAgreement.PrivateKey
  ) throws -> Curve25519.KeyAgreement.PrivateKey {
    // Read path: existing 32B file → reconstruct PrivateKey.
    do {
      let bytes = try TeamKeystore.readX25519Private(at: root)
      return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
    } catch LeafError.keyFileUnavailable {
      // File missing — fall through to gen path.
    }
    // .keyFileCorrupted / Curve25519 init throws propagate (not caught).

    // Gen path: generate + atomically persist.
    let priv = generate()
    try TeamKeystore.writeX25519Private(priv.rawRepresentation, at: root)
    return priv
  }

  /// Delete the on-disk X25519 private file. Idempotent — no-op when the
  /// file is already absent. Building block for user-confirmed «Reset
  /// identity» recovery flow when `register_pubkey` returns a TOFU 409
  /// collision against an auth_id the local app no longer remembers
  /// (e.g. partial wipe scenarios). Caller is responsible for also
  /// clearing the Supabase session store + asking the user to restart
  /// the app — `ensureLocalIdentity` will generate a fresh pair on next
  /// call, but anything that referenced the previous pubkey (team_members
  /// rows server-side, team_keys, workspace memberships) is unrecoverable
  /// from the client's side.
  public static func deleteLocalIdentity(
    at root: URL = TeamKeystore.defaultRoot()
  ) throws {
    let fileURL = root.appendingPathComponent(
      TeamKeystore.x25519PrivateFilename, isDirectory: false
    )
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return }
    do {
      try fm.removeItem(at: fileURL)
    } catch {
      throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
    }
  }
}
