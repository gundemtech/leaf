import Foundation
import AppKit
import ApplicationServices
import os
import LeafCore

/// Phase 4.10.B — listens to `NSWorkspace.didActivateApplicationNotification`
/// (app switch) + a polling tick every `attentionWindowPollIntervalSec` (in-app
/// window-change detection). Pure decision logic is extracted into
/// `AttentionEmissionPlanner` (LeafCore) — the collector holds only the wiring.
///
/// The notification callback is dispatched on the `.main` queue (mandatory — NSWorkspace is
/// not thread-safe). The polling tick also performs AX reads on the main thread (the AX API
/// is not thread-safe within a single process). `@unchecked Sendable` is justified because
/// the internal state (planner.lastBundleID/Title, observer, pollTask)
/// is read/written only from main.
final class ActiveAppCollector: @unchecked Sendable {
    private let writer: EventWriter
    private let blocklist: Set<String>
    private let planner: AttentionEmissionPlanner
    private let pollIntervalSec: TimeInterval

    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?

    init(
        writer: EventWriter,
        blocklist: Set<String>,
        policy: AttentionGranularityPolicy = DefaultAttentionGranularityPolicy(),
        classifier: any AppCategoryClassifier = EmptyAppCategoryClassifier(),
        contextProvider: WindowContextProvider = AXWindowContextProvider(),
        trustChecker: AXTrustChecker = RealAXTrustChecker(),
        pollIntervalSec: TimeInterval = 30
    ) {
        self.writer = writer
        self.blocklist = blocklist
        self.planner = AttentionEmissionPlanner(
            policy: policy,
            classifier: classifier,
            contextProvider: contextProvider,
            trustChecker: trustChecker
        )
        self.pollIntervalSec = pollIntervalSec
    }

    func start() {
        let writer = self.writer
        let blocklist = self.blocklist
        let planner = self.planner

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard let bundleID = app.bundleIdentifier else {
                collectorLogger.debug("Activation without bundle ID — dropped")
                return
            }
            guard !blocklist.contains(bundleID) else {
                return
            }

            if let event = planner.plan(
                bundleID: bundleID,
                pid: app.processIdentifier,
                reason: .appSwitch
            ) {
                Task { await writer.enqueue(event) }
            }
        }

        // Phase 4.10.B — polling tick for in-app window changes
        // (Xcode switching between files, Slack between channels, browser
        // between tabs). The NSWorkspace activation observer catches only
        // app switches; internal title changes are available only through AX poll.
        let intervalNs = UInt64(pollIntervalSec * 1_000_000_000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                await self?.runPollTickOnMain()
            }
        }

        collectorLogger.info("ActiveAppCollector started (windowPoll=\(self.pollIntervalSec, privacy: .public)s)")
    }

    @MainActor
    private func runPollTickOnMain() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              !blocklist.contains(bundleID) else { return }

        if let event = planner.plan(
            bundleID: bundleID,
            pid: app.processIdentifier,
            reason: .windowPoll
        ) {
            await writer.enqueue(event)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        pollTask?.cancel()
        pollTask = nil
        collectorLogger.info("ActiveAppCollector stopped")
    }
}

// MARK: - Real AX implementations

/// Production `AXTrustChecker` — `AXIsProcessTrusted()`. A cached result would be
/// incorrect (the user can toggle the permission in System Settings at runtime),
/// so we make a fresh call every time.
struct RealAXTrustChecker: AXTrustChecker {
    func isAXTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}

/// Production `WindowContextProvider` — reads the focused window title and (for
/// the browser category) the tab URL via the AX API. ADR-010: title bar text is not
/// content (we don't read the document body), the URL is taken from AXWebArea.
struct AXWindowContextProvider: WindowContextProvider {
    func windowTitle(forPid pid: pid_t, bundleID: String) -> String? {
        guard let window = focusedOrFallbackWindow(forPid: pid) else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success else { return nil }
        return titleRef as? String
    }

    func browserURL(forPid pid: pid_t, bundleID: String) -> String? {
        guard let window = focusedOrFallbackWindow(forPid: pid) else { return nil }
        // BFS-ish search for AXWebArea with a depth cap — most browsers
        // place AXWebArea at level 2-4 (window → group → tab → web area).
        return findWebAreaURL(in: window, depthRemaining: 8)
    }

    /// Phase 4.10.B paper-cut: some apps (Xcode confirmed) return
    /// `AXFocusedWindow` only while frontmost. Between the NSWorkspace activation
    /// notification and our AX read the user may already have switched → focused = nil
    /// → no title is written. Fallback chain: focused → main → first of the windows
    /// array — yields stable titlebar text even for backgrounded apps.
    private func focusedOrFallbackWindow(forPid pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        if let win = copyAXWindow(appElement, attribute: kAXFocusedWindowAttribute) {
            return win
        }
        if let win = copyAXWindow(appElement, attribute: kAXMainWindowAttribute) {
            return win
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement],
              let first = windows.first else { return nil }
        return first
    }

    private func copyAXWindow(_ appElement: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            attribute as CFString,
            &ref
        ) == .success,
              let value = ref else { return nil }
        // AXUIElementGetTypeID() guard for the case where the attribute exists but is not window-shaped.
        if CFGetTypeID(value) != AXUIElementGetTypeID() { return nil }
        return (value as! AXUIElement)
    }

    /// Recursively walks AX tree looking for an element whose role is
    /// `AXWebArea`. Returns its `AXURL` value.
    private func findWebAreaURL(in element: AXUIElement, depthRemaining: Int) -> String? {
        guard depthRemaining >= 0 else { return nil }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        ) == .success,
           let role = roleRef as? String,
           role == "AXWebArea" {
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXURLAttribute as CFString,
                &urlRef
            ) == .success {
                if let url = urlRef as? URL { return url.absoluteString }
                if let str = urlRef as? String { return str }
            }
            return nil
        }

        // Descend into children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findWebAreaURL(in: child, depthRemaining: depthRemaining - 1) {
                return found
            }
        }
        return nil
    }
}
