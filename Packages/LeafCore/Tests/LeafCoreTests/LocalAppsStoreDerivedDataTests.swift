import Foundation
// Phase Track-6 P2 — System Observers DerivedData watcher toggle.
import Testing

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

@Suite("LocalAppsStore.derivedDataWatcherEnabled")
struct LocalAppsStoreDerivedDataTests {
    private func makeStore() -> LocalAppsStore {
        let suite = "tech.gundem.leaf.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return LocalAppsStore(defaults: defaults)
    }

    @Test func defaultsOff() {
        let s = makeStore()
        #expect(s.derivedDataWatcherEnabled() == false)
    }

    @Test func setAndGetTrue() {
        let s = makeStore()
        s.setDerivedDataWatcherEnabled(true)
        #expect(s.derivedDataWatcherEnabled() == true)
    }

    @Test func toggleRoundTrip() {
        let s = makeStore()
        s.setDerivedDataWatcherEnabled(true)
        s.setDerivedDataWatcherEnabled(false)
        #expect(s.derivedDataWatcherEnabled() == false)
    }
}
// swiftlint:enable force_unwrapping
