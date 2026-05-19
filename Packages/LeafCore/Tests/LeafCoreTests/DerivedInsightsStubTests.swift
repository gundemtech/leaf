import XCTest
@testable import LeafCore

final class DerivedInsightsStubRecentLastCommitTests: XCTestCase {
    func testStubReturnsNilForRecentLastCommit() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-recent-commit-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
        let stub = StubInsights(database: db)
        XCTAssertNil(try stub.recentLastCommit(maxAgeMs: 4 * 60 * 60 * 1000))
    }
}
