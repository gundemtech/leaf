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
    private let contextProvider: WindowContextProvider
    private let trustChecker: AXTrustChecker

    private var lastBundleID: String?
    private var lastWindowTitle: String?

    /// Жёсткий cap на длину window title — защита от UI mishaps и DB bloat.
    /// Совпадает с capacity, ожидаемым `ActivityFeedMapper` /
    /// `SessionFeedMapper`.
    public static let titleMaxLength = 200

    /// Жёсткий cap на длину browser URL. Длинные query-string'и и base64
    /// fragments обрезаем — moat-сохраняющий tradeoff (точность vs storage).
    public static let urlMaxLength = 1024

    public init(
        policy: AttentionGranularityPolicy,
        contextProvider: WindowContextProvider,
        trustChecker: AXTrustChecker
    ) {
        self.policy = policy
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
        let canReadContext = level.rawValue >= AttentionGranularityLevel.l3.rawValue
            && trustChecker.isAXTrusted()

        if canReadContext {
            if let raw = contextProvider.windowTitle(forPid: pid, bundleID: bundleID),
               let sanitized = sanitizeTitle(raw) {
                payload["window_title"] = sanitized
            }

            // Browser URL — только для browse-категории (Safari / Chrome / Arc / ...).
            if AppCategoryClassifier.category(for: bundleID) == .browse,
               let raw = contextProvider.browserURL(forPid: pid, bundleID: bundleID),
               let sanitized = sanitizeURL(raw) {
                payload["browser_url"] = sanitized
            }
        }

        let title = payload["window_title"]

        // Diff suppression — только для polling tick'ов. App switch всегда emit.
        if reason == .windowPoll,
           bundleID == lastBundleID,
           title == lastWindowTitle {
            return nil
        }

        lastBundleID = bundleID
        lastWindowTitle = title

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

    private func sanitizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= Self.urlMaxLength { return trimmed }
        return String(trimmed.prefix(Self.urlMaxLength))
    }
}
