//
//  ShareTemplateButton.swift
//  Leaf
//
//  Phase 5.5.B — three-channel share button: Mail (mailto:) / Messages (sms:) / Copy (NSPasteboard).
//  Open URL via NSWorkspace.shared.open(_:); Mail/Messages пусть macOS resolves default handler.
//

import SwiftUI
import AppKit
import LeafCore

struct ShareTemplateButton: View {
    let templateBody: String
    let mailSubject: String
    /// Optional callback on copy — UI may flash a "Copied" affordance.
    var onCopy: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copyToPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)

            Button {
                openMail()
            } label: {
                Label("Mail", systemImage: "envelope")
            }
            .buttonStyle(.bordered)

            Button {
                openMessages()
            } label: {
                Label("Messages", systemImage: "message")
            }
            .buttonStyle(.bordered)
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
