import XCTest
@testable import LeafCore

/// End-to-end check of the encrypted path: Database.openForWrite/Read with EncryptionOptions
/// actually encrypts the file, and only the correct key can read it.
final class SQLCipherIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteThenReopenWithSameKeyReadsData() throws {
        let key = EncryptionOptions(keyProvider: .data(Data(repeating: 0xAA, count: 32)))

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: key)
            try writer.write(RawEvent(timestamp: ts, signalType: .attention, bundleID: "com.app"))
            try writer.checkpointWAL()   // force a flush into the main file, otherwise DatabasePool may keep data in .wal
        }

        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: key)
        let range = DateInterval(start: ts.addingTimeInterval(-10), end: ts.addingTimeInterval(10))
        let read = try reader.events(in: range)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].bundleID, "com.app")
    }

    func testReopenWithWrongKeyThrows() throws {
        let keyA = EncryptionOptions(keyProvider: .data(Data(repeating: 0xAA, count: 32)))
        let keyB = EncryptionOptions(keyProvider: .data(Data(repeating: 0xBB, count: 32)))

        do {
            let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: keyA)
            try writer.write(RawEvent(signalType: .attention, bundleID: "com.app"))
            try writer.checkpointWAL()
        }

        // Opening with the wrong key may throw either at open (prepareDatabase executes PRAGMA key),
        // or on the first actual read (GRDB may defer init). We try both points.
        XCTAssertThrowsError(try {
            let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: keyB)
            _ = try reader.events(in: DateInterval(start: .distantPast, duration: 86_400_000))
        }())
    }

    func testFileHeaderIsNotPlaintextSQLite() throws {
        let key = EncryptionOptions(keyProvider: .data(Data(repeating: 0xCC, count: 32)))
        do {
            let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: key)
            try writer.write(RawEvent(signalType: .attention, bundleID: "com.app"))
            try writer.checkpointWAL()
        }

        let handle = try FileHandle(forReadingFrom: dbURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        XCTAssertEqual(header.count, 16)
        XCTAssertNotEqual(header, Data("SQLite format 3\0".utf8),
                          "Encrypted DB must not start with plaintext SQLite magic bytes")
    }

    func testNilEncryptionCreatesPlaintextHeader() throws {
        do {
            let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
            try writer.write(RawEvent(signalType: .attention, bundleID: "com.app"))
            try writer.checkpointWAL()
        }

        let handle = try FileHandle(forReadingFrom: dbURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        XCTAssertEqual(header, Data("SQLite format 3\0".utf8),
                       "Plaintext SQLite must start with magic bytes 'SQLite format 3\\0'")
    }
}
