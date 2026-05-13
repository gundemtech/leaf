import Foundation

/// Phase Track-4 S3 — emission gate для Downloads FSEvents. Accepts created
/// files, rejects directories / hidden files / `.DS_Store`. **Filename only**
/// (ADR-010 Won't-list — никогда не читает file contents).
public struct DownloadsMatcher: Sendable {
    /// `kFSEventStreamEventFlagItemCreated` = 0x100. Hardcoded mirror — avoid
    /// CoreServices import в pure-Swift matcher (testable без framework).
    public static let createdFlag: UInt32 = 0x100

    public init() {}

    public func shouldEmit(
        eventFlags: UInt32,
        isDirectory: Bool,
        filename: String
    ) -> Bool {
        guard (eventFlags & Self.createdFlag) != 0 else { return false }
        guard !isDirectory else { return false }
        guard !filename.hasPrefix(".") else { return false }
        guard filename != ".DS_Store" else { return false }
        return true
    }
}
