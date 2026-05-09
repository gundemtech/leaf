//
//  LeafNavRow.swift
//  Track 2 / D1 — Organism O3. Sidebar nav row — icon + title + optional
//  badge + optional keyboard shortcut · states rest / hover / selected.
//

import SwiftUI

struct LeafNavRow: View {
    let icon: String
    let title: String
    var badge: Int? = nil
    var shortcut: String? = nil
    @Binding var isSelected: Bool
    let onTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: LeafSpace.sm) {
                LeafIcon(
                    systemName: icon,
                    size: .md,
                    tint: isSelected ? LeafColor.accent.primary : LeafColor.text.secondary
                )
                Text(title)
                    .font(LeafType.body.regular)
                    .foregroundStyle(isSelected ? LeafColor.text.primary : LeafColor.text.secondary)
                Spacer()
                if let badge, badge > 0 {
                    LeafBadge(count: badge)
                }
                if let shortcut {
                    LeafKeyboardShortcut(glyphs: shortcut)
                }
            }
            .padding(.horizontal, LeafSpace.md)
            .frame(height: LeafNavRowTokens.height)
            .background(
                RoundedRectangle(cornerRadius: LeafNavRowTokens.cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .leafAnimation(LeafMotion.spring.snappy, value: hover)
    }

    private var backgroundFill: Color {
        if isSelected { return LeafColor.accent.subtle }
        if hover { return LeafColor.surface.raised }
        return Color.clear
    }
}
