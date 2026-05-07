//
//  InviteURLHandler.swift
//  Leaf
//
//  Phase 5.5.B — central glue для `leaf://invite/...` deep-links И NSPasteboard.general
//  auto-detect on app foreground / sheet open. Routes:
//   - InviteURL.parse success → InviteAcceptReader.fetch(inviteURL:)
//   - JoinCode на pasteboard (admin-side) → InviteOutboxReader.generate(inviteeJoinCode:)
//
//  Не interval-poll'ит pasteboard — только реактивные триггеры (URL open / app foreground / explicit sheet open).
//

import Foundation
import AppKit
import OSLog
import Observation
import LeafCore

@MainActor
@Observable
final class InviteURLHandler {
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "invite-url")

    // Weak refs — readers owned by LeafApp, handler — peer service.
    private weak var acceptReader: InviteAcceptReader?
    private weak var outboxReader: InviteOutboxReader?

    /// Last clipboard match observed (для UI affordances "Detected Join code: ABCD...").
    /// Не хранит pubkey bytes — только тип события (UI достаёт fresh value через `probeClipboardForJoinCode()`).
    private(set) var lastDetectedKind: DetectedKind = .none

    enum DetectedKind: Equatable {
        case none
        case inviteURL
        case joinCode
    }

    func wire(acceptReader: InviteAcceptReader, outboxReader: InviteOutboxReader) {
        self.acceptReader = acceptReader
        self.outboxReader = outboxReader
    }

    /// Called from `.onOpenURL` (LeafApp Window scene). User clicked `leaf://invite/...` link.
    func handle(_ url: URL) {
        switch InviteURL.parse(url) {
        case .success:
            logger.info("opened deep-link invite — routing to AcceptReader")
            acceptReader?.fetch(inviteURL: url)
        case .failure:
            logger.warning("ignored non-matching URL scheme: \(url.absoluteString, privacy: .public)")
        }
    }

    /// Called by AcceptInviteSheet on appear ИЛИ LeafApp on `applicationDidBecomeActive`.
    /// Returns Match для UI affordance ("Found invite link in clipboard — Use it?"); side-effect:
    /// updates `lastDetectedKind` для @Observable subscribers.
    @discardableResult
    func probeClipboard() -> ClipboardMatcher.Match {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.isEmpty else {
            lastDetectedKind = .none
            return .none
        }
        let result = ClipboardMatcher.match(raw)
        switch result {
        case .inviteURL: lastDetectedKind = .inviteURL
        case .joinCode:  lastDetectedKind = .joinCode
        case .none:      lastDetectedKind = .none
        }
        return result
    }
}
