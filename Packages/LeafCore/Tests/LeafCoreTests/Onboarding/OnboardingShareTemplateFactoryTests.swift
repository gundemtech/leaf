// Track-10 T1 / C4 — public factory + protocol substrate for the onboarding
// share-controls auto-template. Default impl returns []; moat registers a
// concrete preset list at app launch via `OnboardingShareTemplateFactory.register`.

import XCTest

@testable import LeafCore

final class OnboardingShareTemplateFactoryTests: XCTestCase {
    override func tearDown() async throws {
        // Restore the default empty provider so cross-test pollution can't
        // leak through the static singleton.
        OnboardingShareTemplateFactory.register(EmptyOnboardingShareTemplateProvider())
    }

    func testDefaultProvider_returnsEmptyList() {
        OnboardingShareTemplateFactory.register(EmptyOnboardingShareTemplateProvider())
        XCTAssertEqual(OnboardingShareTemplateFactory.current.defaultTemplate(), [])
    }

    func testRegisterProvider_currentReturnsRegisteredEntries() {
        let stub = StubProvider(entries: [
            BundleAppEntry(bundleID: "com.example.A", displayName: "A"),
            BundleAppEntry(bundleID: "com.example.B", displayName: "B", defaultEnabled: false),
        ])
        OnboardingShareTemplateFactory.register(stub)
        XCTAssertEqual(OnboardingShareTemplateFactory.current.defaultTemplate(), stub.entries)
    }

    func testReRegister_replacesPreviousProvider_lastWriteWins() {
        let first = StubProvider(entries: [BundleAppEntry(bundleID: "first", displayName: "First")])
        let second = StubProvider(entries: [BundleAppEntry(bundleID: "second", displayName: "Second")])
        OnboardingShareTemplateFactory.register(first)
        OnboardingShareTemplateFactory.register(second)
        XCTAssertEqual(OnboardingShareTemplateFactory.current.defaultTemplate(), second.entries)
    }

    func testEmptyProvider_isNotCachedAfterReplacement() {
        OnboardingShareTemplateFactory.register(EmptyOnboardingShareTemplateProvider())
        XCTAssertEqual(OnboardingShareTemplateFactory.current.defaultTemplate(), [])
        let stub = StubProvider(entries: [BundleAppEntry(bundleID: "x", displayName: "X")])
        OnboardingShareTemplateFactory.register(stub)
        XCTAssertEqual(OnboardingShareTemplateFactory.current.defaultTemplate().count, 1)
    }
}

private struct StubProvider: OnboardingShareTemplateProvider {
    let entries: [BundleAppEntry]
    func defaultTemplate() -> [BundleAppEntry] { entries }
}
