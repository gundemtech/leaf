// Phase 5.2.A — IdentityService tests.
// Idempotent read-or-generate semantics: first call generates + persists 32B
// X25519 priv to <root>/x25519.priv (0o600); second call reads existing file
// и returns same key. Mirror OrgServiceTests tempDir setUp/tearDown discipline.

import CryptoKit
import XCTest

@testable import LeafCore

final class IdentityServiceTests: XCTestCase {

  private var tempRoot: URL!

  override func setUp() async throws {
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-identity-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempRoot)
  }

  // MARK: - 1. Generate + persist на пустом root

  func testEnsureLocalIdentity_NoFile_GeneratesAndPersists() throws {
    let priv = try IdentityService.ensureLocalIdentity(at: tempRoot)

    let fileURL = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let onDisk = try Data(contentsOf: fileURL)
    XCTAssertEqual(onDisk.count, 32)
    XCTAssertEqual(onDisk, priv.rawRepresentation)

    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    XCTAssertEqual(perms?.int16Value, 0o600)
  }

  // MARK: - 2. Existing file → read, не generate

  func testEnsureLocalIdentity_FileExists_ReadsExisting() throws {
    let sentinel = Curve25519.KeyAgreement.PrivateKey()
    try TeamKeystore.writeX25519Private(sentinel.rawRepresentation, at: tempRoot)

    let read = try IdentityService.ensureLocalIdentity(at: tempRoot)

    XCTAssertEqual(read.rawRepresentation, sentinel.rawRepresentation)
  }

  // MARK: - 3. Corrupted file → throws (length mismatch propagates, не silent regenerate)

  func testEnsureLocalIdentity_CorruptedFile_Throws() throws {
    // Bypass TeamKeystore length-validation: write 31B raw напрямую.
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let fileURL = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename)
    let bad = Data(repeating: 0x00, count: 31)
    try bad.write(to: fileURL, options: [.atomic])

    XCTAssertThrowsError(try IdentityService.ensureLocalIdentity(at: tempRoot)) { error in
      guard let leafError = error as? LeafError else {
        XCTFail("Expected LeafError, got \(error)")
        return
      }
      switch leafError {
      case .keyFileCorrupted: break
      default:
        XCTFail("Expected .keyFileCorrupted, got \(leafError)")
      }
    }
  }

  // MARK: - 4. Two consecutive calls → identical key (gen-then-read composition)

  func testEnsureLocalIdentity_TwoConsecutiveCalls_ReturnSameKey() throws {
    let first = try IdentityService.ensureLocalIdentity(at: tempRoot)
    let second = try IdentityService.ensureLocalIdentity(at: tempRoot)

    XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
  }

  // MARK: - 5. Subdir create is idempotent

  func testEnsureLocalIdentity_KeystoreSubdirCreatedIdempotently() throws {
    // tempRoot does not exist yet — TeamKeystore writeAtomic must create parent.
    let first = try IdentityService.ensureLocalIdentity(at: tempRoot)
    // Second call against same root — должно работать, no error.
    let second = try IdentityService.ensureLocalIdentity(at: tempRoot)

    XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
  }

  // MARK: - 5b. deleteLocalIdentity — recovery primitive

  func testDeleteLocalIdentity_FileExists_Removes() throws {
    _ = try IdentityService.ensureLocalIdentity(at: tempRoot)
    let fileURL = tempRoot.appendingPathComponent(TeamKeystore.x25519PrivateFilename)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    try IdentityService.deleteLocalIdentity(at: tempRoot)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testDeleteLocalIdentity_FileAbsent_NoOpNoThrow() throws {
    // No prior ensureLocalIdentity — file doesn't exist yet.
    XCTAssertNoThrow(try IdentityService.deleteLocalIdentity(at: tempRoot))
  }

  func testDeleteLocalIdentity_FollowedByEnsure_RegeneratesFreshKey() throws {
    let first = try IdentityService.ensureLocalIdentity(at: tempRoot)
    try IdentityService.deleteLocalIdentity(at: tempRoot)
    let second = try IdentityService.ensureLocalIdentity(at: tempRoot)
    XCTAssertNotEqual(
      first.rawRepresentation, second.rawRepresentation,
      "post-delete ensure must generate a fresh key, not return the old one"
    )
  }

  // MARK: - 6. Injected generator используется только при gen-path (lazy)

  func testEnsureLocalIdentity_InjectedGenerator_UsedOnlyOnFirstCall() throws {
    let injected = Curve25519.KeyAgreement.PrivateKey()
    let counter = CallCounter()

    let first = try IdentityService.ensureLocalIdentity(
      at: tempRoot,
      generate: {
        counter.increment()
        return injected
      })
    XCTAssertEqual(first.rawRepresentation, injected.rawRepresentation)
    XCTAssertEqual(counter.value, 1)

    // Second call — should hit read path, generator must NOT be invoked again.
    let second = try IdentityService.ensureLocalIdentity(
      at: tempRoot,
      generate: {
        counter.increment()
        return Curve25519.KeyAgreement.PrivateKey()  // different key — would mismatch если invoked
      })
    XCTAssertEqual(second.rawRepresentation, injected.rawRepresentation)
    XCTAssertEqual(counter.value, 1, "generate() must not be called when file exists")
  }
}

/// Sendable counter для inject'абельного `generate:` closure.
/// `@Sendable` closure не может mutate'ить captured var, but reference-type
/// поверх NSLock — Sendable-safe.
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = 0

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    _value += 1
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }
}
