//
//  TokensPreviewScreen.swift
//  Track 2 / D1 — Debug-only storybook behind ⌘⌥T. Renders all 28 components +
//  T2 token sections in a scrollable single-window view. Light/Dark/Auto
//  switcher, reduceMotion override, force-fallback-glass toggle.
//

import SwiftUI

#if DEBUG
struct TokensPreviewScreen: View {
    @State private var appearance: PreviewAppearance = .auto
    @State private var reduceMotionOverride: Bool = false
    @State private var forceLegacyGlass: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxxl) {
                header
                TokensColorSection()
                TokensTypeSection()
                TokensSpaceSection()
                TokensRadiusSection()
                TokensElevationSection()
                TokensGlassSection(forceLegacy: $forceLegacyGlass)
                TokensMotionSection()
                TokensIconsSection()
                AtomsSection()
                MoleculesSection()
                OrganismsSection()
                MetricsSection()
                TemplatesSection()
            }
            .padding(LeafSpace.xxl)
        }
        .background(LeafColor.surface.canvas.ignoresSafeArea())
        .preferredColorScheme(appearance.colorScheme)
        .environment(\.leafReduceMotionOverride, reduceMotionOverride)
        .environment(\.forceLegacyGlass, forceLegacyGlass)
        .frame(minWidth: 960, minHeight: 720)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Leaf Design Tokens").font(LeafType.display.regular)
                    .foregroundStyle(LeafColor.text.primary)
                Text(versionBanner).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
            }
            Spacer()
            Picker("Appearance", selection: $appearance) {
                ForEach(PreviewAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Toggle("Reduce motion", isOn: $reduceMotionOverride)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private var versionBanner: String {
        if #available(macOS 26, *) { return "Running on macOS 26 — Liquid Glass available" }
        return "Running on macOS 14/15 — Material fallback path"
    }
}

enum PreviewAppearance: String, CaseIterable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var label: String {
        switch self { case .light: "Light"; case .dark: "Dark"; case .auto: "Auto" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .auto: nil }
    }
}
#endif
