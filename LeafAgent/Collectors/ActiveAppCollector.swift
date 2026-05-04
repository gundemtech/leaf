import Foundation
import AppKit
import ApplicationServices
import os
import LeafCore

/// Phase 4.10.B — слушает `NSWorkspace.didActivateApplicationNotification`
/// (app switch) + polling tick раз в `attentionWindowPollIntervalSec` (in-app
/// window-change detection). Pure decision logic вынесена в
/// `AttentionEmissionPlanner` (LeafCore) — collector держит только wiring.
///
/// Notification callback диспатчится на `.main` queue (mandatory — NSWorkspace не
/// thread-safe). Polling tick тоже выполняет AX read'ы на main thread (AX API
/// не thread-safe для одного процесса). `@unchecked Sendable` оправдан тем,
/// что внутреннее состояние (planner.lastBundleID/Title, observer, pollTask)
/// читается/пишется только с main.
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

        // Phase 4.10.B — polling tick для in-app window changes
        // (Xcode переключение между файлами, Slack между каналами, browser
        // между табами). NSWorkspace activation observer ловит только
        // app-switch'и; внутренние title changes доступны только через AX poll.
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

/// Production `AXTrustChecker` — `AXIsProcessTrusted()`. Cached result был бы
/// неверным (юзер может toggled permission в System Settings runtime'но),
/// поэтому делаем fresh call каждый раз.
struct RealAXTrustChecker: AXTrustChecker {
    func isAXTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}

/// Production `WindowContextProvider` — читает focused window title и (для
/// browser-категории) tab URL через AX API. ADR-010: title bar text не есть
/// content (мы не читаем body документа), URL берётся из AXWebArea.
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
        // BFS-ish search для AXWebArea с глубиной cap'ом — большинство браузеров
        // помещают AXWebArea на 2-4 уровне (window → group → tab → web area).
        return findWebAreaURL(in: window, depthRemaining: 8)
    }

    /// Phase 4.10.B paper-cut: некоторые apps (Xcode подтверждённо) возвращают
    /// `AXFocusedWindow` только когда frontmost. Между NSWorkspace activation
    /// notification и нашим AX read юзер уже мог переключиться → focused = nil
    /// → title не пишется. Fallback chain: focused → main → first из windows
    /// array — даёт стабильный titlebar text даже для backgrounded apps.
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
        // AXUIElementGetTypeID() guard на случай когда attribute exists но не window-shaped.
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
