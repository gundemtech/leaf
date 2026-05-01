import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryTests: XCTestCase {

    /// Каждый case в `ShareEventTypeKey.allCases` должен иметь default entry —
    /// guard против забытого default'а при добавлении нового event_kind.
    func testAllKeysHaveDefaults() {
        let allKeys = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        let defaultKeys = Set(ShareEventTypeDefaults.all.map { $0.key.rawValue })
        XCTAssertEqual(allKeys, defaultKeys,
                       "Each ShareEventTypeKey case must have ShareEventTypeDefault entry")
    }

    /// rawValue uniqueness — два case'а не могут иметь одинаковый
    /// payload.event_kind discriminator.
    func testKeysAreUnique() {
        let raws = ShareEventTypeKey.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(raws).count, raws.count, "All event_kind raws must be unique")
    }

    /// Phase 4.7.A — ровно 11 новых keys добавлено относительно baseline 11
    /// (4.4 = 10 + 4.6.B = 1). Если этот тест ломается при добавлении
    /// 4.7.B/4.7.C — обновить counter сознательно.
    func testPhase47ARegistrySize() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 22,
                       "Phase 4.7.A baseline = 11 + 11 new = 22 keys total")
    }

    /// Discussions default OFF (нишевые). Verify that key design intent сохранён.
    func testDiscussionsDefaultOff() {
        let dDefault = ShareEventTypeDefaults.all.first { $0.key == .githubDiscussionAuthored }
        XCTAssertEqual(dDefault?.defaultEnabled, false)
        let dcDefault = ShareEventTypeDefaults.all.first { $0.key == .githubDiscussionCommentAuthored }
        XCTAssertEqual(dcDefault?.defaultEnabled, false)
    }
}
