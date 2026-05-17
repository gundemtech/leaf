import CoreAudio
import Foundation
import LeafCore
import os

/// Phase Track-4 S3 — CoreAudio default output device transport-type observer.
/// Maps `kAudioDevicePropertyTransportType` (UInt32) to narrow
/// `AudioRouteCategory` enum; device names / manufacturer info никогда не
/// материализуется (ADR-010 Won't-list — audio_route → transport-type enum
/// only).
///
/// Listener attaches к default-output-device-changed property; callback
/// re-fetches current device + transport type. Initial seed observation на
/// start чтобы first transition после restart был visible.
@MainActor
final class AudioRouteCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private var stateMachine = AudioRouteStateMachine()
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listenerInstalled = false

    init(writer: EventWriter, observersStore: SystemObserversStore) {
        self.writer = writer
        self.observersStore = observersStore
    }

    func start() async {
        guard observersStore.isEnabled("audio_route") else {
            collectorLogger.info("AudioRouteCollector disabled by master toggle")
            return
        }
        installListener()
        // Seed state with current category (no emit — state-machine first-obs nil).
        _ = stateMachine.observe(currentRouteCategory())
        collectorLogger.info("AudioRouteCollector started")
    }

    func stop() async {
        if listenerInstalled { removeListener() }
        collectorLogger.info("AudioRouteCollector stopped")
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Hop to main actor для state-machine mutation.
            Task { @MainActor in
                await self?.tickOnce()
            }
        }
        listenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            listenerInstalled = true
        } else {
            collectorLogger.error("AudioObjectAddPropertyListenerBlock failed status=\(status, privacy: .public)")
        }
    }

    private func removeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
        listenerInstalled = false
    }

    private func tickOnce() async {
        let category = currentRouteCategory()
        guard let transition = stateMachine.observe(category) else { return }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "audio_route_changed",
                Schema.EventPayloadKeys.audioRoute: transition.rawValue,
            ]
        )
        await writer.enqueue(raw)
        collectorLogger.info("Audio route -> \(transition.rawValue, privacy: .public)")
    }

    /// Reads kAudioHardwarePropertyDefaultOutputDevice → then transport type.
    /// **NEVER** reads kAudioDevicePropertyDeviceName / manufacturer / model UID.
    private func currentRouteCategory() -> AudioRouteCategory {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return .unknown }
        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport
        )
        guard tStatus == noErr else { return .unknown }
        return Self.mapTransport(transport)
    }

    static func mapTransport(_ raw: UInt32) -> AudioRouteCategory {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtin
        case kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        default: return .unknown
        }
    }
}
