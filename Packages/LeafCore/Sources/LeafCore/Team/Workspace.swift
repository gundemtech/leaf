import Foundation

/// Phase Track-5 S2 — multi-workspace identity value type (replaces single-org
/// `Org` model). One Mac device = N workspaces; each has independent teamKey
/// material. Stored в `workspaces` table (Schema.Workspaces, M019).
///
/// `createdByMemberID` — logical FK на `team_members.id`; SQL FOREIGN KEY
/// не объявляется (mirror Org 5.1.B convention).
///
/// `leftAt` IS NULL = active membership. Non-NULL = soft-mark from
/// `WorkspaceService.markLeft` (OQ-T5-2 resolution — data preserved, UI hides
/// from active list). Hard-wipe ("Wipe workspace data") is opt-in Settings
/// action deferred to S8 Settings restructure (Track 5 contract §16 OQ-T5-2).
public struct Workspace: Sendable, Hashable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let createdByMemberID: String
    public let leftAt: Date?

    public init(
        id: String,
        name: String,
        createdAt: Date,
        createdByMemberID: String,
        leftAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.createdByMemberID = createdByMemberID
        self.leftAt = leftAt
    }
}
