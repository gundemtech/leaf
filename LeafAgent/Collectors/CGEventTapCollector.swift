import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import LeafCore
import os
final class CGEventTapCollector: @unchecked Sendable {
    private struct CounterState {
        var keystrokes: UInt32 = 0
        var mouseMoves: UInt32 = 0
        var appSwitches: UInt32 = 0
    }

    private let writer: EventWriter
    private let systemStateCollector: SystemStateCollector
    private let observersStore: SystemObserversStore
    private let permissionStore: InputMonitoringPermissionStore
    private let database: LeafCore.Database
    private let minuteBucketSec: TimeInterval

    private let counterLock = OSAllocatedUnfairLock<CounterState>(initialState: CounterState())
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTask: Task<Void, Never>?
    private var appSwitchObserver: NSObjectProtocol?

    init(
        writer: EventWriter,
        systemStateCollector: SystemStateCollector,
        observersStore: SystemObserversStore,
        permissionStore: InputMonitoringPermissionStore,
        database: LeafCore.Database,
        minuteBucketSec: TimeInterval
    ) {
        self.writer = writer
        self.systemStateCollector = systemStateCollector
        self.observersStore = observersStore
        self.permissionStore = permissionStore
        self.database = database
        self.minuteBucketSec = minuteBucketSec
    }

    func start() async {
        guard observersStore.isEnabled("intensity") else {
            collectorLogger.info("CGEventTapCollector disabled by master toggle")
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard permissionStore.shouldProbe(nowMs: nowMs) else {
            collectorLogger.info("CGEventTapCollector — Input Monitoring denied (backoff)")
            return
        }
        let probe = Self.probeAccess()
        permissionStore.record(probe.state, nowMs: nowMs)
        guard probe.granted else {
            collectorLogger.info("CGEventTapCollector — Input Monitoring not granted, no tap install")
            return
        }
        await installTap()
        await installAppSwitchObserver()
        flushTask = Task.detached { [weak self] in
            await self?.runMinuteFlushLoop()
        }
        collectorLogger.info("CGEventTapCollector started")
    }

    func stop() async {
        flushTask?.cancel()
        flushTask = nil
        await uninstallAppSwitchObserver()
        await uninstallTap()
        collectorLogger.info("CGEventTapCollector stopped")
    }

    // MARK: - Permission probe

    private struct PermissionProbe {
        let state: InputMonitoringPermissionState
        let granted: Bool
    }

    private static func probeAccess() -> PermissionProbe {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            return PermissionProbe(state: .granted, granted: true)
        case kIOHIDAccessTypeDenied:
            return PermissionProbe(state: .denied(Int64(Date().timeIntervalSince1970 * 1000)), granted: false)
        case kIOHIDAccessTypeUnknown:
            // First-time probe — request access. Returns granted bool sync.
            let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            if ok {
                return PermissionProbe(state: .granted, granted: true)
            } else {
                return PermissionProbe(state: .denied(Int64(Date().timeIntervalSince1970 * 1000)), granted: false)
            }
        default:
            return PermissionProbe(state: .unavailable, granted: false)
        }
    }

    // MARK: - Tap install / uninstall

    @MainActor
    private func installTap() {
        let mask: UInt64 =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: Self.tapCallback,
                userInfo: refcon
            )
        else {
            collectorLogger.error("CGEvent.tapCreate returned nil — tap not installed")
            return
        }
        machPort = port
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    @MainActor
    private func uninstallTap() {
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        runLoopSource = nil
        machPort = nil
    }

    // MARK: - App-switch observer (sibling counter)

    @MainActor
    private func installAppSwitchObserver() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.counterLock.withLock { state in
                state.appSwitches = state.appSwitches &+ 1
            }
        }
    }

    @MainActor
    private func uninstallAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        appSwitchObserver = nil
    }

    // MARK: - C tap callback (counter-only — ADR-010 Won't-list)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<CGEventTapCollector>.fromOpaque(refcon).takeUnretainedValue()
        return me.handleTapEvent(type: type, event: event)
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Auto-recovery on tap drop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        }
        // System-state gate — drop counter increments while AFK.
        // SystemStateCollector mutates isLocked/isSleeping on @MainActor + read
        // boundaries are simple Bool loads; assume atomic per ARM64 LDR/STR on
        // word-sized scalars. Worst case (ABA): one bucket boundary off-by-one.
        let locked = MainActor.assumeIsolated { systemStateCollector.isLocked }
        let sleeping = MainActor.assumeIsolated { systemStateCollector.isSleeping }
        if locked || sleeping { return Unmanaged.passUnretained(event) }

        // Counter-only discrimination. NEVER reads .keycode / .characters /
        // .modifierFlags / .location / .unicodeStringValue.
        counterLock.withLock { state in
            switch type {
            case .keyDown:
                state.keystrokes = state.keystrokes &+ 1
            case .leftMouseDown, .rightMouseDown, .mouseMoved,
                .leftMouseDragged, .rightMouseDragged, .scrollWheel:
                state.mouseMoves = state.mouseMoves &+ 1
            default:
                break
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Minute-boundary flush loop

    private func runMinuteFlushLoop() async {
        let accumulator = IntensityBucketAccumulator()
        let intervalSec = minuteBucketSec
        while !Task.isCancelled {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // Wait until next wall-clock boundary aligned to intervalSec.
            let bucketSizeMs = Int64(intervalSec * 1000)
            let nextBoundaryMs = ((nowMs / bucketSizeMs) + 1) * bucketSizeMs
            let sleepNs = UInt64(max(0, nextBoundaryMs - nowMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: sleepNs)
            if Task.isCancelled { break }

            // Atomic snapshot+reset of counters.
            let counters: CounterState = counterLock.withLock { state in
                let snapshot = state
                state = CounterState()
                return snapshot
            }

            // Bucket boundary just crossed — the bucket that *just ended* is
            // nextBoundaryMs - bucketSize.
            let flushedNowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let bucketMs = ((flushedNowMs / bucketSizeMs) - 1) * bucketSizeMs

            // @MainActor reads for system-state + frontmost-app snapshot.
            let frontApp = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
            let wasLocked = await MainActor.run { self.systemStateCollector.isLocked }
            let wasSleeping = await MainActor.run { self.systemStateCollector.isSleeping }

            let snapshot = accumulator.flushTo(
                bucketMs: bucketMs,
                keystrokes: counters.keystrokes,
                mouseMoves: counters.mouseMoves,
                appSwitches: counters.appSwitches,
                foregroundApp: frontApp,
                wasLocked: wasLocked,
                wasSleeping: wasSleeping
            )

            // UPSERT into intensity_aggregates — idempotent on PK
            // minute_bucket_ms. `try?` — DB unavailable shouldn't block flush
            // loop; next tick retries on новых counters.
            try? database.upsertIntensityAggregate(
                minuteBucketMs: snapshot.minuteBucketMs,
                keystrokes: Int(snapshot.keystrokes),
                mouseMoves: Int(snapshot.mouseMoves),
                appSwitches: Int(snapshot.appSwitches),
                foregroundApp: snapshot.foregroundApp
            )

            // RawEvent emit — skip пустых active buckets (no signal).
            if snapshot.droppedReason != nil || snapshot.keystrokes > 0 || snapshot.mouseMoves > 0
                || snapshot.appSwitches > 0
            {
                let payload = snapshot.toRawEventPayload()
                let raw = RawEvent(signalType: .context, bundleID: nil, payload: payload)
                await writer.enqueue(raw)
            }
        }
    }
}
