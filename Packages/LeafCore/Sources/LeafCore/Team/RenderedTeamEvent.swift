//
//  RenderedTeamEvent.swift
//  LeafCore
//
//  M-IX — presentation carrier for a single team-event feed row. Bundles the
//  raw TeamEventMirrorRow with its precomputed action text so the view never
//  parses payload JSON during render.
//
//  The single designated init derives actionText eagerly, so a RenderedTeamEvent
//  can never exist without its derived string (no stale/empty path).
//

import Foundation

public struct RenderedTeamEvent: Identifiable, Equatable, Sendable {

    public let row: TeamEventMirrorRow
    public let actionText: String

    public var id: String { row.eventID }

    public init(row: TeamEventMirrorRow) {
        self.row = row
        self.actionText = TeamEventActionText.make(for: row)
    }
}
