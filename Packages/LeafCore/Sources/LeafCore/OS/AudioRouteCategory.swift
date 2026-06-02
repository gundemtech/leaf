import Foundation

/// Phase Track-4 S3 — narrow enum for CoreAudio transport-type categorization.
/// Device name / manufacturer info is never materialized (ADR-010
/// Won't-list — "Prohibited" §"audio_route → transport-type enum (no device
/// names)"). raw kAudioDevicePropertyTransportType (UInt32) is mapped to this
/// enum in `AudioRouteCollector`.
public enum AudioRouteCategory: String, Sendable, Hashable, CaseIterable {
    case builtin
    case headphones
    case bluetooth
    case airplay
    case usb
    case displayPort
    case hdmi
    case unknown
}
