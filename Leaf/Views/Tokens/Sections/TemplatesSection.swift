//
//  TemplatesSection.swift
//  Track 2 / D1 — populated by Tasks 39–42 (T1 Window / T2 Sheet / T3 MenuBar / T4 OnboardingStep).
//

import SwiftUI

#if DEBUG
struct TemplatesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            Text("Templates").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            LeafWindowLayoutPreview()
            LeafSheetLayoutPreview()
        }
    }
}
#endif
