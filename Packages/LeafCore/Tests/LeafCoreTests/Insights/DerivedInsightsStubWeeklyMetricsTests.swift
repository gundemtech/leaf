import XCTest

@testable import LeafCore

final class DerivedInsightsStubWeeklyMetricsTests: XCTestCase {
    func testWeeklyMetricsDefaultReturnsEmpty() throws {
        // StubInsights requires a Database — minimal temp DB for type satisfaction;
        // StubInsights.weeklyMetrics never touches it.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-stub-weekly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let insights = StubInsights(database: db)
        let result = try insights.weeklyMetrics(now: Date())
        XCTAssertEqual(result, WeeklyMetrics.empty)
    }
}
