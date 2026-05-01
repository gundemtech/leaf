import SwiftUI

/// 24-hour bar showing peak productivity hour highlighted in olive.
/// Stage 3 simplification: bars are equal-height ambient context, only the peak
/// hour gets accent. When per-hour metrics ship, bars become real values.
struct PeakFocusChart: View {
    let peakHour: Int?

    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PEAK FOCUS")
                        .leafLabelStyle()
                    Spacer()
                    Text(peakLabel)
                        .font(.leafCaption)
                        .foregroundStyle(.leafMuted)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<24, id: \.self) { hour in
                        bar(for: hour)
                    }
                }
                .frame(height: 64)
                HStack {
                    Text("00")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("23")
                }
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
            }
        }
    }

    private var peakLabel: String {
        guard let h = peakHour else { return "Collecting…" }
        return String(format: "%02d:00", h)
    }

    private func bar(for hour: Int) -> some View {
        let isPeak = hour == peakHour
        let height: CGFloat = isPeak ? 56 : (hour % 3 == 0 ? 24 : 16)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isPeak ? Color.leafAccentDeep : Color.leafMuted.opacity(0.35))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
