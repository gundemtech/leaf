import Foundation

public struct IDEsCardPayload: Equatable, Sendable {
    public let fileEventCount: Int
    public let workspaceCount: Int
    public let vscodeFamilyEventCount: Int
    public let jetbrainsEventCount: Int
    /// `ide_window_title_observed` sum — fallback path when per-fork title
    /// parser cannot extract a workspace/file from the window title.
    public let fallbackTitleCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet computed".
    public let dailyEvents: [Double]

    public init(
        fileEventCount: Int,
        workspaceCount: Int,
        vscodeFamilyEventCount: Int,
        jetbrainsEventCount: Int,
        fallbackTitleCount: Int,
        dailyEvents: [Double]
    ) {
        self.fileEventCount = fileEventCount
        self.workspaceCount = workspaceCount
        self.vscodeFamilyEventCount = vscodeFamilyEventCount
        self.jetbrainsEventCount = jetbrainsEventCount
        self.fallbackTitleCount = fallbackTitleCount
        self.dailyEvents = dailyEvents
    }
}
