import Foundation

/// Phase Track-6 P5 — Public protocol for redacting owner-PII patterns from
/// Zoom meeting topic strings before they reach the state machine. Critical
/// for the Personal Meeting Room (PMI) format `<First> <Last>'s Personal
/// Meeting Room` which leaks the meeting owner's legal name.
///
/// Production implementation in LeafCorePrivate applies a regex strip and
/// returns "<pmi_meeting>" bucket. LeafCore consumers stay regex-free.
public protocol ZoomMeetingTopicRedactor: Sendable {
    func redact(_ raw: String) -> String
}

/// Test/default pass-through. Returns input unchanged.
public struct IdentityZoomMeetingTopicRedactor: ZoomMeetingTopicRedactor {
    public init() {}
    public func redact(_ raw: String) -> String { raw }
}
