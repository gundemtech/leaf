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
import EventKit
import Intents
import IOKit.hid
import LeafCore
import OSLog

@MainActor
@Observable
final class PermissionsService {
    private(set) var axGranted: Bool = false
    private(set) var fdaGranted: Bool = false
    /// Phase Track-4 S1 — Calendar full-access TCC grant state.
    private(set) var calendarGranted: Bool = false
    /// Phase Track-4 S1 — Focus status TCC grant state.
    private(set) var focusGranted: Bool = false
    /// Phase Track-4 S3 — Input Monitoring TCC grant state. Drives the
    /// "Intensity monitoring" row в SystemObserversSettingsSection.
    private(set) var inputMonitoringGranted: Bool = false

    /// Phase Track-4 S2 — shared Local Apps preference store (per-app enabled
    /// flag + per-(app, sub-field) opt-in). Backed by UserDefaults; both the
    /// Settings UI and the Agent's `AppleScriptCollector` read this store.
    let localAppsStore: LocalAppsStore
    /// Phase Track-4 S2 — TCC state cache for per-app AppleScript grants
    /// (24h denial backoff). Same UserDefaults backing as the Agent's instance.
    let localAppsPermissionStore: AppleScriptPermissionStore

    /// Phase Track-4 S3 — shared System Observers preference store (master
    /// toggles для intensity / clipboard / wifi / vpn / audio / mic / display
    /// / screenshot_watcher / downloads_watcher / trash_watcher). Backed
    /// UserDefaults; same suite that LocalAppsStore + OAuth services use.
    let systemObserversStore: SystemObserversStore
    /// Phase Track-4 S3 — Input Monitoring TCC state cache (24h denial
    /// backoff). Same UserDefaults backing as the Agent's instance.
    let inputMonitoringPermissionStore: InputMonitoringPermissionStore

    /// Track-6 P1 — shared AI Tools preference store (master Claude Code toggle
    /// + per-feature sub-toggles like `claude_code.tokens`). Backed by the same
    /// UserDefaults suite as LocalAppsStore + SystemObserversStore.
    let aiToolsStore: AIToolsStore

    private var pollTimer: Timer?
    private let axCheck: @Sendable () -> Bool
    private let fdaCheck: @Sendable () -> Bool
    private let calendarCheck: @Sendable () -> Bool
    private let focusCheck: @Sendable () -> Bool
    private let inputMonitoringCheck: @Sendable () -> Bool
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "permissions")

    init(
        axCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        fdaCheck: @escaping @Sendable () -> Bool = { PermissionsService.defaultFDAProbe() },
        calendarCheck: @escaping @Sendable () -> Bool = { PermissionsService.defaultCalendarProbe() },
        focusCheck: @escaping @Sendable () -> Bool = { PermissionsService.defaultFocusProbe() },
        inputMonitoringCheck: @escaping @Sendable () -> Bool = { PermissionsService.defaultInputMonitoringProbe() },
        localAppsStore: LocalAppsStore = LocalAppsStore(),
        localAppsPermissionStore: AppleScriptPermissionStore = AppleScriptPermissionStore(),
        systemObserversStore: SystemObserversStore = SystemObserversStore(),
        inputMonitoringPermissionStore: InputMonitoringPermissionStore = InputMonitoringPermissionStore(),
        aiToolsStore: AIToolsStore = AIToolsStore()
    ) {
        self.axCheck = axCheck
        self.fdaCheck = fdaCheck
        self.calendarCheck = calendarCheck
        self.focusCheck = focusCheck
        self.inputMonitoringCheck = inputMonitoringCheck
        self.localAppsStore = localAppsStore
        self.localAppsPermissionStore = localAppsPermissionStore
        self.systemObserversStore = systemObserversStore
        self.inputMonitoringPermissionStore = inputMonitoringPermissionStore
        self.aiToolsStore = aiToolsStore
        refresh()
    }

    // MARK: - State

    func refresh() {
        axGranted = axCheck()
        fdaGranted = fdaCheck()
        calendarGranted = calendarCheck()
        focusGranted = focusCheck()
        inputMonitoringGranted = inputMonitoringCheck()
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

    /// Phase Track-6 P3 — alias for the Safari bookmark watcher FDA CTA.
    func openFDAPane() {
        openFDASettings()
    }

    // MARK: - Phase Track-4 S1 — Calendar + Focus grant flow

    /// Triggers Calendar permission prompt via EventKit. On first call shows
    /// the system modal; on subsequent calls (denial state cached by TCC) the
    /// callback fires immediately with the current status. Deep-link to
    /// Settings via `openCalendarSettings()` is the graceful re-grant path.
    func triggerCalendarPrompt() {
        Task {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            }
            await MainActor.run { self.refresh() }
        }
    }

    func triggerFocusPrompt() {
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openCalendarSettings() {
        openSystemSettings("Privacy_Calendars")
    }

    func openFocusSettings() {
        openSystemSettings("Privacy_Focus")
    }

    // MARK: - Phase Track-4 S2 — Local Apps grant flow

    /// Deep-link to System Settings → Privacy → Automation. Used when the
    /// user denied TCC for an AppleScript adapter and wants to re-grant.
    func openAutomationSettings() {
        openSystemSettings("Privacy_Automation")
    }

    /// Settings UI calls this when the user flips the Local Apps toggle for
    /// `bundleID`. Wraps `LocalAppsStore.setEnabled` so the Observable
    /// surface is in sync.
    func setLocalAppEnabled(_ bundleID: String, _ enabled: Bool) {
        localAppsStore.setEnabled(bundleID, enabled)
    }

    /// Settings UI calls this when the user flips a per-app sub-field opt-in
    /// (Mail "mailboxName" / Zoom "ownMeetingTopic").
    func setLocalAppSubFieldOptedIn(_ bundleID: String, field: String, optedIn: Bool) {
        localAppsStore.setSubFieldOptedIn(bundleID, field: field, optedIn: optedIn)
    }

    // MARK: - Phase Track-4 S3 — Input Monitoring grant flow

    /// Triggers Input Monitoring TCC dialog via `IOHIDRequestAccess`. Surfaces
    /// the system modal under `tech.gundem.leaf` first time; agent gets its
    /// own dialog under `tech.gundem.leaf.agent` on its first start tick.
    /// Synchronous bool return; refresh updates `inputMonitoringGranted`.
    func triggerInputMonitoringPrompt() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        inputMonitoringPermissionStore.record(
            granted ? .granted : .denied(nowMs),
            nowMs: nowMs
        )
        refresh()
    }

    /// Deep-link to System Settings → Privacy → Input Monitoring. Re-grant
    /// path после denial (TCC silent'но прокатывает second prompt).
    func openInputMonitoringSettings() {
        openSystemSettings("Privacy_ListenEvent")
    }

    /// Settings UI calls this when the user flips a system-observer toggle.
    func setSystemObserverEnabled(_ observer: String, _ enabled: Bool) {
        systemObserversStore.setEnabled(observer, enabled)
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

    /// Phase Track-4 S1 — Calendar probe. `.fullAccess` is the only state we
    /// accept; `.writeOnly` / `.denied` / `.restricted` / `.notDetermined` all
    /// return false.
    nonisolated static func defaultCalendarProbe() -> Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
        return false
    }

    /// Phase Track-4 S1 — Focus probe.
    nonisolated static func defaultFocusProbe() -> Bool {
        INFocusStatusCenter.default.authorizationStatus == .authorized
    }

    /// Phase Track-4 S3 — Input Monitoring probe. Read-only TCC check
    /// (doesn't surface dialog). `triggerInputMonitoringPrompt()` is the
    /// path that does — separates read from request.
    nonisolated static func defaultInputMonitoringProbe() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
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
