import XCTest
@testable import LeafCore

final class SupabaseConfigTests: XCTestCase {
    private final class StubBundle: Bundle, @unchecked Sendable {
        var dictionary: [String: Any] = [:]
        override func object(forInfoDictionaryKey key: String) -> Any? { dictionary[key] }
    }

    func testReadsURLFromBundle() {
        let bundle = StubBundle()
        bundle.dictionary = ["LeafSupabaseURL": "https://example.supabase.co"]
        XCTAssertEqual(SupabaseConfig.baseURL(from: bundle),
                       URL(string: "https://example.supabase.co")!)
    }

    func testReadsAnonKeyFromBundle() {
        let bundle = StubBundle()
        bundle.dictionary = ["LeafSupabaseAnonKey": "test-anon-key"]
        XCTAssertEqual(SupabaseConfig.anonKey(from: bundle), "test-anon-key")
    }
}
