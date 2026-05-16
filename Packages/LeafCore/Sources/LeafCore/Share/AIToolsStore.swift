import Foundation
import Observation

/// Track-6 P1 — UserDefaults-backed observable store for AI Tools preference state.
/// Mirrors `SystemObserversStore` / `LocalAppsStore` shape — Settings UI and
/// Onboarding read/write via `isEnabled(_:)` / `setEnabled(_:_:)`.
///
/// Keys (`leaf.aitools.<feature>`):
///   - `claude_code` — master Claude Code toggle (drives hook install/uninstall)
///   - `claude_code.tokens` — sub-toggle gating `claude_tokens_used` jsonl emission
///                           (consumed by Phase 4.9 Derived Insights downstream)
///
/// `lastInstallResult` exposes the most recent `AIToolsHookInstaller.install/uninstall`
/// outcome so the Settings UI can render a status badge without re-running probe logic.
@Observable
public final class AIToolsStore: @unchecked Sendable {
    public enum InstallResult: Equatable, Sendable {
        case notAttempted
        case ok
        case failed(String)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix = "leaf.aitools."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ key: String) -> Bool {
        defaults.bool(forKey: keyPrefix + key)
    }

    public func setEnabled(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    /// Most recent hook install/uninstall outcome — driven by Settings UI / Onboarding
    /// after they call AIToolsHookInstaller. Not persisted across launches.
    public var lastInstallResult: InstallResult = .notAttempted
}
