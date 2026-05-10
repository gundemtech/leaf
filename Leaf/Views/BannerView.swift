//
//  BannerView.swift
//  Leaf
//
//  Phase 3.4 — reusable inline banner для MenuBarContent: agent-off,
//  permission-denied и future warnings. Color параметр окрашивает только
//  иконку — текст остаётся system primary/secondary для accessibility
//  contrast (low-contrast colored text проблематично для vision).
//

import SwiftUI

struct BannerView: View {
    let color: Color
    let title: String
    var subtitle: String? = nil
    let action: String
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image.leafAsset(LeafIcons.status.warningFill)
                .frame(width: 14, height: 14)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action, action: onTap)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
