//
//  PermissionsService.swift
//  Leaf
//
//  Phase 3.4 — runtime AX + FDA permission status для onboarding flow и
//  permissionsBanner в MenuBarContent. Polling-based: TCC не шлёт Darwin
//  notification на grant/revoke, единственный способ детектировать —
//  периодический query. Hybrid lifecycle: 1с интервал в onboarding (UX),
//  4с в normal popover (battery).
//

import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import OSLog

@MainActor
@Observable
final class PermissionsService {
    private(set) var axGranted: Bool = false
    private(set) var fdaGranted: Bool = false

    private var pollTimer: Timer?
    private let axCheck: @Sendable () -> Bool
    private let fdaCheck: @Sendable () -> Bool
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "permissions")

    init(
        axCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        fdaCheck: @escaping @Sendable () -> Bool = { PermissionsService.defaultFDAProbe() }
    ) {
        self.axCheck = axCheck
        self.fdaCheck = fdaCheck
        refresh()
    }

    // MARK: - State

    func refresh() {
        axGranted = axCheck()
        fdaGranted = fdaCheck()
    }

    // MARK: - Polling

    /// Idempotent — повторный вызов перезапускает таймер с новым интервалом.
    /// Hybrid lifecycle: OnboardingView вызывает с 1.0s (UX responsiveness),
    /// MenuBarContent с 4.0s (battery, banner reactivity).
    func startPolling(every seconds: TimeInterval = 2.0) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - User-initiated grant flow

    /// Показывает system AX prompt sheet — но только в первый раз для свежей
    /// TCC entry. После denial Apple silent'но прокатывает prompt → нужен
    /// `openAXSettings()` deep-link как fallback. Безопасно вызывать оба.
    /// String literal вместо `kAXTrustedCheckOptionPrompt` — imported C global
    /// не Sendable в Swift 6 strict; значение константы стабильно.
    func triggerAXPrompt() {
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func openAXSettings() {
        openSystemSettings("Privacy_Accessibility")
    }

    func openFDASettings() {
        openSystemSettings("Privacy_AllFiles")
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            logger.error("invalid System Settings URL for pane \(pane, privacy: .public)")
            return
        }
        if !NSWorkspace.shared.open(url) {
            logger.warning("NSWorkspace.open failed for \(pane, privacy: .public)")
        }
    }

    // MARK: - Default probes

    /// FDA не имеет programmatic API. Proxy: попытка `contentsOfDirectory`
    /// над `~/Library/Application Support/com.apple.TCC` — readable только
    /// при FDA grant. Семантика error codes:
    ///   - `NSCocoaErrorDomain` Code=260 (NSFileReadNoSuchFileError) → assume
    ///     granted (probe сам отсутствует, false positive безвреден; banner
    ///     просто не покажется, при первом FSEvents-event collector сам поймёт).
    ///   - `NSPOSIXErrorDomain` Code=1 (EPERM) → denied.
    ///   - другие → denied (defensive default).
    nonisolated static func defaultFDAProbe() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: probe)
            return true
        } catch let err as NSError where err.domain == NSCocoaErrorDomain && err.code == 260 {
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Test plan
//
// Real XCTestCase'ы wire'ятся когда LeafTests Xcode target создаётся
// (Phase 3.5+). XCTest framework не линкуется в app target — `#if DEBUG`
// compile-only невозможен. Cases ниже — execution-ready spec.
//
// Helper:
//   final class MutableBox<T> { var value: T; init(_ v: T) { value = v } }
//
// 1. testRefreshReadsInjectedClosures
//    Init с `axCheck = { true }`, `fdaCheck = { false }`. Assert
//    `axGranted == true && fdaGranted == false` после init (init вызывает
//    refresh). Проверяет что closures wire'd корректно.
//
// 2. testRefreshPicksUpStateChange
//    Использует MutableBox<Bool>. Closures читают `box.value`. Init с box=true,
//    assert axGranted==true. Set box.value = false. Call svc.refresh(). Assert
//    axGranted==false. Доказывает что refresh re-evaluate'т closures, не
//    кеширует первое значение.
//
// 3. testPollingStartStopIdempotent
//    Counter MutableBox<Int>, axCheck increment'ит. Snapshot baseline.
//    startPolling(every: 0.05). Sleep 200ms. Snapshot mid (assert >2 increments).
//    stopPolling(). Sleep 200ms. Snapshot after (assert ≤1 increment vs mid —
//    допускает один in-flight Task который запустился до stopPolling).
//    Доказывает что таймер запущен, потом остановлен.
//
// 4. testFDAProbeMissingDirReturnsTrue
//    Создаёт PermissionsService с custom fdaCheck, который имитирует ту же
//    try/catch shape для несуществующего пути (`/tmp/nonexistent-\(UUID())`).
//    Assert returns true (NoSuchFile branch — NSCocoaError 260). Подтверждает
//    что D4 graceful fallback работает.
