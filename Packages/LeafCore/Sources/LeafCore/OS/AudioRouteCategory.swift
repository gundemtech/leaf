import Foundation

/// Phase Track-4 S3 — narrow enum для CoreAudio transport-type categorization.
/// Никогда не материализуется device name / manufacturer info (ADR-010
/// Won't-list — "Запрещено" §"audio_route → transport-type enum (no device
/// names)"). raw kAudioDevicePropertyTransportType (UInt32) маппится на этот
/// enum в `AudioRouteCollector`.
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
