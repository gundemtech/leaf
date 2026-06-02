import Foundation

/// Phase Track-4 S3 — pure transition detector for the CoreAudio
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` boolean. Mirrors the Focus
/// state-machine pattern: first observation primes state without an emit;
/// 0→1 emits `.entered`, 1→0 emits `.exited`; same-value repeats no-emit.
public struct MicInUseStateMachine: Sendable, Hashable {
    public enum Transition: Sendable, Hashable {
        case entered
        case exited
    }

    private var lastInUse: Bool?

    public init() {}

    public mutating func observe(_ inUse: Bool) -> Transition? {
        defer { lastInUse = inUse }
        guard let prior = lastInUse else { return nil }
        if prior == inUse { return nil }
        return inUse ? .entered : .exited
    }
}
