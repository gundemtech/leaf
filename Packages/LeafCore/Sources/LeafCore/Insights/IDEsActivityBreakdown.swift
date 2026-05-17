import Foundation

public struct IDEsActivityBreakdown: Sendable, Hashable {
    public let totalEventCount: Int
    public let vscodeFamilyEventCount: Int
    public let jetbrainsEventCount: Int
    public let fallbackTitleCount: Int
    public let workspaceCount: Int
    /// Top 5 workspace names, descending by event count.
    public let topWorkspaces: [String]
    /// Top 5 file basenames, descending by event count.
    public let topFiles: [String]
    /// 7 values (oldest → newest).
    public let dailyEvents: [Double]

    public init(
        totalEventCount: Int,
        vscodeFamilyEventCount: Int,
        jetbrainsEventCount: Int,
        fallbackTitleCount: Int,
        workspaceCount: Int,
        topWorkspaces: [String],
        topFiles: [String],
        dailyEvents: [Double]
    ) {
        self.totalEventCount = totalEventCount
        self.vscodeFamilyEventCount = vscodeFamilyEventCount
        self.jetbrainsEventCount = jetbrainsEventCount
        self.fallbackTitleCount = fallbackTitleCount
        self.workspaceCount = workspaceCount
        self.topWorkspaces = topWorkspaces
        self.topFiles = topFiles
        self.dailyEvents = dailyEvents
    }

    public static let empty = IDEsActivityBreakdown(
        totalEventCount: 0,
        vscodeFamilyEventCount: 0,
        jetbrainsEventCount: 0,
        fallbackTitleCount: 0,
        workspaceCount: 0,
        topWorkspaces: [],
        topFiles: [],
        dailyEvents: []
    )
}
