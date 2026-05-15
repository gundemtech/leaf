//
//  SlackChannelsProviding.swift
//  LeafCore
//
//  Track 5 / S6 T11 — narrow Sendable surface used by `SlackChannelsReader`
//  to fetch the viewer's accessible Slack channels for the cross-post
//  channel picker UI.
//
//  Why a separate protocol from the collector-tier `SlackProviding`:
//   - Reader needs only one call (`conversations.list` with the viewer's
//     joined channels), no token / cursor / paging surface.
//   - Keeps the test stub tiny (one method to fake).
//   - Decouples the cross-post UI from collector-tier provider evolution.
//
//  Production impl lives in `LeafCorePrivate` (moat). The stub in this file
//  returns an empty list so non-LeafCorePrivate builds (CI / dev) compile
//  and the picker UI shows the "no channels" empty state instead of
//  crashing on missing impl.
//

import Foundation

/// Fetches the Slack channels the current user can post into. Empty array
/// is a valid response — caller (UI) shows an empty state, never an error.
public protocol SlackChannelsProviding: Sendable {
    /// Returns the viewer's accessible channels. Implementations should
    /// filter to channels the bot/user can post to (`chat:write` allowed)
    /// — UI relies on the result being post-capable.
    func fetchAccessibleChannels() async throws -> [SlackChannelsReader.SlackChannel]
}

/// Stub for CI / dev-without-moat builds. Returns an empty list — the
/// channel picker UI surfaces "no channels yet — re-authorize Slack" copy.
public struct StubSlackChannelsProvider: SlackChannelsProviding {
    public init() {}
    public func fetchAccessibleChannels() async throws -> [SlackChannelsReader.SlackChannel] {
        []
    }
}
