import Foundation

/// Phase 5.1.B — organization metadata value type. Single-row-per-device
/// (Phase 5 architecture contract §4 — single-org-per-device); хранится
/// в `org` таблице (Schema.Org, M006).
///
/// `createdByMemberID` — logical FK на `team_members.id`; SQL FOREIGN KEY
/// не объявляется (5.1.A spec §4 "FK strategy") — insertion-order paradox
/// при `createPersonalOrg` (5.1.D), валидация через Swift value-types.
public struct Org: Sendable, Hashable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let createdByMemberID: String

    public init(
        id: String,
        name: String,
        createdAt: Date,
        createdByMemberID: String
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.createdByMemberID = createdByMemberID
    }
}
