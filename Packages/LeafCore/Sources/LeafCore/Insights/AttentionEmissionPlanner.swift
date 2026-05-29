//
//  AttentionEmissionPlanner.swift
//  LeafCore
//
//  Phase 4.10.B — pure decision logic для attention emission. Принимает
//  (bundleID, pid, reason) + injected `WindowContextProvider` / `AXTrustChecker`
//  / `AttentionGranularityPolicy` → возвращает `RawEvent?` (nil если diff
//  suppression срабатывает на windowPoll).
//
//  Отделён от `ActiveAppCollector` чтобы тесты не зависели от NSWorkspace + AX.
//

import Foundation

/// Отвечает за чтение window-контекста через AX (или эквивалент).
/// Реальная имплементация живёт в LeafAgent (`AXWindowContextProvider`).
public protocol WindowContextProvider: Sendable {
    func windowTitle(forPid pid: pid_t, bundleID: String) -> String?
    func browserURL(forPid pid: pid_t, bundleID: String) -> String?
}

/// Обёртка над `AXIsProcessTrusted()` — выделена в протокол чтобы тесты
/// детерминированно эмулировали обе ветки.
public protocol AXTrustChecker: Sendable {
    func isAXTrusted() -> Bool
}

/// Причина emit'а. App switch — explicit user action (всегда emit). Window
/// poll — internal periodic tick (diff suppression: skip если ничего не
/// изменилось с прошлого раза).
public enum AttentionEmitReason: Sendable {
    case appSwitch
    case windowPoll
}

/// Stateful planner: хранит last-emitted (bundleID, title) для diff
/// suppression. Не Sendable — рассчитан на вызовы с одного потока (main).
public final class AttentionEmissionPlanner {
    private let policy: AttentionGranularityPolicy
    private let classifier: any AppCategoryClassifier
    private let contextProvider: WindowContextProvider
    private let trustChecker: AXTrustChecker

    private var lastBundleID: String?
    private var lastWindowTitle: String?

    /// Жёсткий cap на длину window title — защита от UI mishaps и DB bloat.
    /// Совпадает с capacity, ожидаемым `ActivityFeedMapper` /
    /// `SessionFeedMapper`.
    public static let titleMaxLength = 200

    /// Жёсткий cap на длину browser URL после sanitize. `sanitizeURL` always drops
    /// the fragment + non-allowlisted query, then truncates the result to this length.
    public static let urlMaxLength = 1024

    public init(
        policy: AttentionGranularityPolicy,
        classifier: any AppCategoryClassifier = EmptyAppCategoryClassifier(),
        contextProvider: WindowContextProvider,
        trustChecker: AXTrustChecker
    ) {
        self.policy = policy
        self.classifier = classifier
        self.contextProvider = contextProvider
        self.trustChecker = trustChecker
    }

    /// Главная entry point. Возвращает `RawEvent` для записи или nil если
    /// событие подавлено diff-suppression (только windowPoll).
    public func plan(
        bundleID: String,
        pid: pid_t,
        reason: AttentionEmitReason,
        now: Date = Date()
    ) -> RawEvent? {
        var payload: [String: String] = [:]

        let level = policy.maxGranularity(for: bundleID)
        let canReadContext =
            level.rawValue >= AttentionGranularityLevel.l3.rawValue
            && trustChecker.isAXTrusted()

        if canReadContext {
            if let raw = contextProvider.windowTitle(forPid: pid, bundleID: bundleID),
                let sanitized = sanitizeTitle(raw)
            {
                payload["window_title"] = sanitized
            }

            // Browser URL — только для browse-категории (Safari / Chrome / Arc / ...).
            if classifier.category(for: bundleID) == .browse,
                let raw = contextProvider.browserURL(forPid: pid, bundleID: bundleID),
                let sanitized = Self.sanitizeURL(raw)
            {
                payload["browser_url"] = sanitized
            }
        }

        // Capture original window_title BEFORE vscode-family hook for
        // diff-suppression key (hook below removes window_title and replaces
        // with parsed fields, but suppression must compare apples to apples
        // across ticks).
        let diffKey = payload["window_title"]

        // Track-6 P6 — vscode-family parser hook.
        // If we have a title AND bundle is vscode-family, attempt parsing.
        // On parse success: replace generic attention with vscode_active_doc_changed
        // event_kind (state-machine-diffed downstream by collector).
        // On parse failure: emit ide_window_title_observed fallback with
        // path-sanitized raw_title (default OFF in registry — diagnostic signal).
        if canReadContext,
            let title = payload["window_title"],
            VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: bundleID)
        {
            if let obs = VSCodeFamilyDispatcher.parse(bundleID: bundleID, title: title) {
                payload.removeValue(forKey: "window_title")
                payload["event_kind"] = "vscode_active_doc_changed"
                payload["ide_bundle_id"] = obs.ideBundleID
                if let w = obs.workspaceName { payload["workspace_name"] = w }
                if let f = obs.fileBasename { payload["file_basename"] = f }
            } else {
                payload.removeValue(forKey: "window_title")
                payload["event_kind"] = "ide_window_title_observed"
                payload["ide_bundle_id"] = bundleID
                payload["raw_title"] = IDETitlePathSanitizer.sanitize(title)
            }
        }

        // Diff suppression — только для polling tick'ов. App switch всегда emit.
        if reason == .windowPoll,
            bundleID == lastBundleID,
            diffKey == lastWindowTitle
        {
            return nil
        }

        lastBundleID = bundleID
        lastWindowTitle = diffKey

        return RawEvent(
            timestamp: now,
            signalType: .attention,
            bundleID: bundleID,
            payload: payload
        )
    }

    // MARK: - Sanitization

    private func sanitizeTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= Self.titleMaxLength { return trimmed }
        return String(trimmed.prefix(Self.titleMaxLength))
    }

    /// Browser URL sanitizer (privacy). Always drops the fragment (it can carry
    /// OAuth implicit-flow tokens / JWTs / magic-link secrets — audit HIGH H1) and
    /// any userinfo; drops the entire query for non-allowlisted hosts and keeps only
    /// a narrow per-host query-key allowlist (search terms) otherwise. Truncates to
    /// `urlMaxLength`. Falls back to a string-split (drops `#…` then `?…`) when the
    /// input is not a parseable http/https URL, so fragment/query never leaks even
    /// from malformed input. Returns nil only when empty after trim.
    static func sanitizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard var comps = URLComponents(string: trimmed),
            let scheme = comps.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = comps.host?.lowercased()
        else {
            return privacySafeFallback(trimmed)
        }

        comps.fragment = nil
        comps.user = nil
        comps.password = nil

        let allowed = allowlistedQueryKeys(forHost: host)
        if allowed.isEmpty {
            comps.query = nil
        } else {
            let kept = (comps.queryItems ?? []).filter { allowed.contains($0.name) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }

        guard let rebuilt = comps.string else { return privacySafeFallback(trimmed) }
        return truncateURL(rebuilt)
    }

    /// Per-host query-key allowlist. Default = strip all query. Narrow by design:
    /// only well-known search-engine query params are retained (a Content signal,
    /// local-only, behind AX + per-app opt-in). Matched lowercased + suffix so
    /// `www.google.com` uses the `google.com` entry.
    static let urlQueryAllowlist: [String: Set<String>] = [
        "google.com": ["q"]
    ]

    private static func allowlistedQueryKeys(forHost host: String) -> Set<String> {
        for (domain, keys) in Self.urlQueryAllowlist
        where host == domain || host.hasSuffix("." + domain) {
            return keys
        }
        return []
    }

    /// Fallback for inputs that are not parseable http/https URLs: drop `#…` then
    /// `?…` via string-split, trim, truncate. Guarantees no fragment/query leaks.
    private static func privacySafeFallback(_ s: String) -> String? {
        var value = s
        if let hashIndex = value.firstIndex(of: "#") { value = String(value[..<hashIndex]) }
        if let queryIndex = value.firstIndex(of: "?") { value = String(value[..<queryIndex]) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return truncateURL(trimmed)
    }

    private static func truncateURL(_ s: String) -> String {
        s.count <= Self.urlMaxLength ? s : String(s.prefix(Self.urlMaxLength))
    }
}
