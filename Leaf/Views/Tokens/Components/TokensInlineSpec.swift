//
//  TokensInlineSpec.swift
//  Track 2 / D1 — Reusable "spec footer" caption for each component preview entry.
//  Renders text like "LeafButton.Primary · md · LeafSpace.lg · LeafRadius.md".
//  Includes "Copy snippet" button.
//

import SwiftUI

#if DEBUG
struct TokensInlineSpec: View {
    let spec: String
    let codeSnippet: String

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            Text(spec)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
            Spacer(minLength: LeafSpace.xs)
            Button {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(codeSnippet, forType: .string)
                #endif
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LeafColor.text.tertiary)
            .help("Copy snippet")
        }
        .padding(.top, LeafSpace.xs)
    }
}
#endif
