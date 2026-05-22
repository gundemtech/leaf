import Foundation

/// Track-10 T1 — provider for the onboarding share-controls preset list.
/// Public clones / non-prod builds see only `EmptyOnboardingShareTemplateProvider`
/// (returns `[]`); prod builds register `LeafCorePrivate.ProdOnboardingShareTemplate`
/// at app launch (`LeafApp.swift` adjacent to `DerivedInsightsFactory.register`,
/// inside `#if LEAF_PROD`).
public protocol OnboardingShareTemplateProvider: Sendable {
    func defaultTemplate() -> [BundleAppEntry]
}

/// Fallback used by `OnboardingShareTemplateFactory` until something
/// concrete registers. Returns an empty list — the onboarding panel reads
/// this and renders the "share controls will be configured later" copy.
public struct EmptyOnboardingShareTemplateProvider: OnboardingShareTemplateProvider {
    public init() {}
    public func defaultTemplate() -> [BundleAppEntry] { [] }
}

/// Static singleton — pattern parity with `LocalAppsStore.sharedDefaults` and
/// `DerivedInsightsFactory`. Touched once at app launch (moat register) +
/// once per onboarding flow (UI read); concurrency hazard is negligible.
public enum OnboardingShareTemplateFactory {
    nonisolated(unsafe) private static var _provider: OnboardingShareTemplateProvider =
        EmptyOnboardingShareTemplateProvider()
    private static let lock = NSLock()

    public static func register(_ provider: OnboardingShareTemplateProvider) {
        lock.lock()
        defer { lock.unlock() }
        _provider = provider
    }

    public static var current: OnboardingShareTemplateProvider {
        lock.lock()
        defer { lock.unlock() }
        return _provider
    }
}
