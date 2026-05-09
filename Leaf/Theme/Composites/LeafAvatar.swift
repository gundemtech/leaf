//
//  LeafAvatar.swift
//  Track 2 / D1 — Molecule M8. Circular avatar with initials/image fallback +
//  optional status ring tinted via LeafDotTone (raw lineWidth 2 — not a
//  padding/radius/cornerRadius value, token guard untouched).
//

import SwiftUI

struct LeafAvatar: View {
    let initials: String
    var image: Image? = nil
    var size: LeafAvatarTokens.Size = .md
    var statusRing: LeafDotTone? = nil

    var body: some View {
        ZStack {
            Circle().fill(LeafColor.surface.inset)
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initials)
                    .font(size.font)
                    .foregroundStyle(LeafColor.text.primary)
            }
            if let statusRing {
                Circle().strokeBorder(statusRing.color, lineWidth: 2)
            }
        }
        .frame(width: size.pt, height: size.pt)
    }
}
