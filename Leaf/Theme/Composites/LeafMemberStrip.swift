//
//  LeafMemberStrip.swift
//  Team UI polish — compact overlapping avatar stack replacing the member
//  pill row. Tap → DM sheet (preserves the pill row's send entry point);
//  hover tooltip carries the name the pills used to show.
//

import LeafCore
import SwiftUI

struct LeafMemberStrip: View {
  let members: [TeamMember]
  let onTap: (TeamMember) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(visible.enumerated()), id: \.element.id) { idx, member in
        Button {
          onTap(member)
        } label: {
          LeafAvatar(initials: initials(for: member.displayName), size: .md)
        }
        .buttonStyle(.plain)
        .padding(.leading, idx == 0 ? 0 : -LeafTeamFeedTokens.avatarOverlap)
        .zIndex(Double(visible.count - idx))
        .help("Message \(member.displayName)")
        .accessibilityLabel("Message \(member.displayName)")
      }
      if overflowCount > 0 {
        Text("+\(overflowCount)")
          .font(LeafType.caption)
          .foregroundStyle(LeafColor.text.secondary)
          .padding(.leading, LeafSpace.xs)
      }
    }
  }

  private var visible: [TeamMember] {
    Array(members.prefix(LeafTeamFeedTokens.memberStripVisibleCap))
  }

  private var overflowCount: Int {
    max(0, members.count - LeafTeamFeedTokens.memberStripVisibleCap)
  }

  private func initials(for name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
      .compactMap { $0.first.map(String.init) }
      .joined()
      .uppercased()
    return parts.isEmpty ? "?" : parts
  }
}
