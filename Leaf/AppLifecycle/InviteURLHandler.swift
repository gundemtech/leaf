//
//  InviteURLHandler.swift
//  Leaf
//
//  Phase 5.5.B — central glue for `leaf://invite/...` deep-links AND NSPasteboard.general
//  auto-detect on app foreground / sheet open. Routes:
//   - InviteURL.parse success → InviteAcceptReader.fetch(inviteURL:)
//   - JoinCode on the pasteboard (admin-side) → InviteOutboxReader.generate(inviteeJoinCode:)
//
//  Does not interval-poll the pasteboard — only reactive triggers (URL open / app foreground / explicit sheet open).
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
    /// M027 invite-redesign — drives the new closed-mode submit flow.
    private weak var joinRequestsReader: JoinRequestsReader?
    /// M027 — used by handle()/handleCodePaste() to surface the waiting card
    /// + pre-fill the paste sheet from a clicked link.
    private weak var windowState: WindowState?

    /// Last clipboard match observed (for UI affordances "Detected Join code: ABCD...").
    /// Does not store pubkey bytes — only the event kind (UI fetches a fresh value via `probeClipboardForJoinCode()`).
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

    /// M027 invite-redesign — late-bind the join-request reader + WindowState
    /// (LeafApp calls this in .onAppear alongside the legacy wire(...) above).
    func wireM027(joinRequestsReader: JoinRequestsReader, windowState: WindowState) {
        self.joinRequestsReader = joinRequestsReader
        self.windowState = windowState
    }

    /// Called from `.onOpenURL` (LeafApp Window scene). User clicked `leaf://invite/...` link.
    /// Dispatches by URL shape:
    ///   - S3 v=1 (`leaf://invite/<22>?w=&a=[#otp]`) → InviteAcceptReader.fetch
    ///   - M027 (`leaf://invite/LEAF-XXXX-XXXX-XXXX`) → WindowState.pendingInviteCode
    ///     (RootView presents JoinWorkspaceByCodeSheet pre-filled)
    func handle(_ url: URL) {
        switch InviteURL.parse(url) {
        case .success:
            logger.info("opened S3 v=1 deep-link — routing to AcceptReader")
            acceptReader?.fetch(inviteURL: url)
        case .failure:
            // Detect M027 new format: leaf://invite/LEAF-XXXX-XXXX-XXXX (no query).
            if let code = Self.extractM027Code(from: url) {
                logger.info("opened M027 deep-link — routing to JoinWorkspaceByCodeSheet")
                windowState?.pendingInviteCode = code
            } else {
                logger.warning("ignored non-matching URL: \(url.absoluteString, privacy: .public)")
            }
        }
    }

    /// JoinWorkspaceByCodeSheet calls this on [Send request]. Submits via
    /// JoinRequestsReader (Edge Function derives workspace_id from the code).
    /// Surfaces the waiting card via WindowState.joinRequestWaitingPresented.
    func handleCodePaste(code: String, displayName: String) {
        joinRequestsReader?.submit(workspaceID: nil, code: code, displayName: displayName)
        windowState?.joinRequestWaitingPresented = true
    }

    private static let m027CodeRegex = try! NSRegularExpression(
        pattern: #"^/(LEAF-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4})$"#
    )

    private static func extractM027Code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "leaf",
              url.host?.lowercased() == "invite" else { return nil }
        let path = url.path
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = m027CodeRegex.firstMatch(in: path, range: range),
              match.numberOfRanges == 2,
              let codeRange = Range(match.range(at: 1), in: path) else {
            return nil
        }
        return String(path[codeRange])
    }

    /// Called by AcceptInviteSheet on appear OR LeafApp on `applicationDidBecomeActive`.
    /// Returns Match for the UI affordance ("Found invite link in clipboard — Use it?"); side-effect:
    /// updates `lastDetectedKind` for @Observable subscribers.
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
