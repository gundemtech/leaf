//
//  PermissionsService.swift
//  Leaf
//
//  Phase 3.4 — runtime AX + FDA permission status for the onboarding flow and
//  the permissionsBanner in MenuBarContent. Polling-based: TCC doesn't send a Darwin
//  notification on grant/revoke, so the only way to detect it is a
//  periodic query. Hybrid lifecycle: 1s interval in onboarding (UX),
//  4s in the normal popover (battery).
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
    /// "Intensity monitoring" row in SystemObserversSettingsSection.
    private(set) var inputMonitoringGranted: Bool = false

    /// Phase Track-4 S2 — shared Local Apps preference store (per-app enabled
    /// flag + per-(app, sub-field) opt-in). Backed by UserDefaults; both the
    /// Settings UI and the Agent's `AppleScriptCollector` read this store.
    let localAppsStore: LocalAppsStore
    /// Phase Track-4 S2 — TCC state cache for per-app AppleScript grants
    /// (24h denial backoff). Same UserDefaults backing as the Agent's instance.
    let localAppsPermissionStore: AppleScriptPermissionStore

    /// Phase Track-4 S3 — shared System Observers preference store (master
    /// toggles for intensity / clipboard / wifi / vpn / audio / mic / display
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

    /// Idempotent — a repeat call restarts the timer with the new interval.
    /// Hybrid lifecycle: OnboardingView calls with 1.0s (UX responsiveness),
    /// MenuBarContent with 4.0s (battery, banner reactivity).
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

    /// Shows the system AX prompt sheet — but only the first time for a fresh
    /// TCC entry. After a denial Apple silently swallows the prompt → an
    /// `openAXSettings()` deep-link is needed as a fallback. Safe to call both.
    /// String literal instead of `kAXTrustedCheckOptionPrompt` — the imported C global
    /// isn't Sendable under Swift 6 strict; the constant's value is stable.
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
    /// path after a denial (TCC silently swallows the second prompt).
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

    /// FDA has no programmatic API. Proxy: attempt `contentsOfDirectory`
    /// over `~/Library/Application Support/com.apple.TCC` — readable only
    /// with an FDA grant. Error-code semantics:
    ///   - `NSCocoaErrorDomain` Code=260 (NSFileReadNoSuchFileError) → assume
    ///     granted (the probe itself is missing, the false positive is harmless; the banner
    ///     just won't show, and on the first FSEvents event the collector figures it out itself).
    ///   - `NSPOSIXErrorDomain` Code=1 (EPERM) → denied.
    ///   - others → denied (defensive default).
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
// Real XCTestCases get wired up once the LeafTests Xcode target is created
// (Phase 3.5+). The XCTest framework doesn't link into the app target — `#if DEBUG`
// compile-only isn't possible. The cases below are an execution-ready spec.
//
// Helper:
//   final class MutableBox<T> { var value: T; init(_ v: T) { value = v } }
//
// 1. testRefreshReadsInjectedClosures
//    Init with `axCheck = { true }`, `fdaCheck = { false }`. Assert
//    `axGranted == true && fdaGranted == false` after init (init calls
//    refresh). Verifies that the closures are wired correctly.
//
// 2. testRefreshPicksUpStateChange
//    Uses MutableBox<Bool>. Closures read `box.value`. Init with box=true,
//    assert axGranted==true. Set box.value = false. Call svc.refresh(). Assert
//    axGranted==false. Proves that refresh re-evaluates the closures rather than
//    caching the first value.
//
// 3. testPollingStartStopIdempotent
//    Counter MutableBox<Int>, axCheck increments it. Snapshot baseline.
//    startPolling(every: 0.05). Sleep 200ms. Snapshot mid (assert >2 increments).
//    stopPolling(). Sleep 200ms. Snapshot after (assert ≤1 increment vs mid —
//    allows for one in-flight Task that started before stopPolling).
//    Proves that the timer is started, then stopped.
//
// 4. testFDAProbeMissingDirReturnsTrue
//    Creates a PermissionsService with a custom fdaCheck that mimics the same
//    try/catch shape for a non-existent path (`/tmp/nonexistent-\(UUID())`).
//    Assert returns true (NoSuchFile branch — NSCocoaError 260). Confirms
//    that the D4 graceful fallback works.
