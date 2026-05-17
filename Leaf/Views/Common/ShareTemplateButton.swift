//
//  ShareTemplateButton.swift
//  Leaf
//
//  Phase 5.5.B — three-channel share button: Mail (mailto:) / Messages (sms:) / Copy (NSPasteboard).
//  Track 2 / D4 — migrated from system .borderedProminent / .bordered to LeafButton primary/secondary.
//

import AppKit
import LeafCore
import SwiftUI

struct ShareTemplateButton: View {
    let templateBody: String
    let mailSubject: String
    /// Optional callback on copy — UI may flash a "Copied" affordance.
    var onCopy: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            LeafButton(
                "Copy",
                variant: .primary,
                icon: .asset(LeafIcons.comm.copy),
                action: copyToPasteboard
            )
            LeafButton(
                "Mail",
                variant: .secondary,
                icon: .asset(LeafIcons.comm.email),
                action: openMail
            )
            LeafButton(
                "Messages",
                variant: .secondary,
                icon: .asset(LeafIcons.comm.message),
                action: openMessages
            )
        }
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(templateBody, forType: .string)
        onCopy?()
    }

    private func openMail() {
        let url = ShareTemplate.mailtoURL(subject: mailSubject, body: templateBody)
        NSWorkspace.shared.open(url)
    }

    private func openMessages() {
        let url = ShareTemplate.smsURL(body: templateBody)
        NSWorkspace.shared.open(url)
    }
}
