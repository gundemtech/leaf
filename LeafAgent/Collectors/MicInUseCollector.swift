import Foundation
import CoreAudio
import os
import LeafCore

/// Phase Track-4 S3 — CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// boolean listener on default input device. Detects ANY process recording
/// from system mic (Zoom / FaceTime / Slack huddle / Voice Memos / etc) —
/// generic "user in voice call" signal.
///
/// **NSMicrophoneUsageDescription НЕ нужен** — property listener не открывает
/// recording, не активирует green-dot indicator, не читает audio samples
/// (ADR-010 Won't-list — mic_in_use → boolean only).
@MainActor
final class MicInUseCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private var stateMachine = MicInUseStateMachine()
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    /// Cached default input device at start(). **Known limitation (I2 review):**
    /// если юзер сменит default input device после start (USB mic plug-in),
    /// listener останется attached к старому. Mirror VPN limitation pattern
    /// (NEVPNManager.shared() also pins к first profile). Document'но
    /// acceptable best-effort; revisit if real signal demands live re-attach.
    private var inputDeviceID: AudioDeviceID = 0
    private var listenerInstalled = false

    init(writer: EventWriter, observersStore: SystemObserversStore) {
        self.writer = writer
        self.observersStore = observersStore
    }

    func start() async {
        guard observersStore.isEnabled("mic_in_use") else {
            collectorLogger.info("MicInUseCollector disabled by master toggle")
            return
        }
        guard let deviceID = currentInputDevice() else {
            collectorLogger.info("MicInUseCollector — no default input device")
            return
        }
        inputDeviceID = deviceID
        installListener()
        // Seed state with current value (no emit — first-obs nil).
        _ = stateMachine.observe(currentInUseValue())
        collectorLogger.info("MicInUseCollector started")
    }

    func stop() async {
        if listenerInstalled { removeListener() }
        collectorLogger.info("MicInUseCollector stopped")
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                await self?.tickOnce()
            }
        }
        listenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            inputDeviceID,
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            listenerInstalled = true
        } else {
            collectorLogger.error("MicInUseCollector listener install failed status=\(status, privacy: .public)")
        }
    }

    private func removeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            inputDeviceID,
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
        listenerInstalled = false
    }

    private func tickOnce() async {
        let inUse = currentInUseValue()
        guard let transition = stateMachine.observe(inUse) else { return }
        let eventKind: String
        let state: String
        switch transition {
        case .entered: eventKind = "mic_in_use_entered"; state = "mic_in_use"
        case .exited:  eventKind = "mic_in_use_exited";  state = "mic_idle"
        }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["event_kind": eventKind, "state": state]
        )
        await writer.enqueue(raw)
        collectorLogger.info("Mic transition -> \(eventKind, privacy: .public)")
    }

    private func currentInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    /// Reads kAudioDevicePropertyDeviceIsRunningSomewhere — UInt32 0/1.
    /// **NEVER** reads audio samples / hooks AVCaptureSession / AVAudioRecorder.
    private func currentInUseValue() -> Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            inputDeviceID, &addr, 0, nil, &size, &running
        )
        return status == noErr && running != 0
    }
}
