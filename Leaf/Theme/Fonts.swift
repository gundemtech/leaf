import SwiftUI

extension Font {
    static let leafTitle    = Font.system(size: 48, weight: .regular,  design: .serif)
    static let leafHeadline = Font.system(size: 24, weight: .semibold, design: .serif)
    static let leafMetric   = Font.system(size: 32, weight: .regular,  design: .serif)
    static let leafLabel    = Font.system(size: 11, weight: .medium,   design: .monospaced)
    static let leafBody     = Font.system(size: 13, weight: .regular,  design: .default)
    static let leafCaption  = Font.system(size: 11, weight: .regular,  design: .default)
}

extension Text {
    func leafLabelStyle() -> some View {
        self.font(.leafLabel)
            .kerning(1.6)
            .textCase(.uppercase)
            .foregroundStyle(.leafMuted)
    }
}
