//
//  LeafAssetImage.swift
//  Track 2 / D1 — Convenience for inline Asset Catalog glyph rendering with
//  template tinting. Covers the 95% of callsites that just want
//  Image.leafAsset(LeafIcons.foo).frame(width: ..., height: ...).
//

import SwiftUI

extension Image {
    /// Asset Catalog template-rendered glyph from the LeafIcons.* namespace.
    /// Caller adds .frame(width:height:) and .foregroundStyle(...) downstream.
    static func leafAsset(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
