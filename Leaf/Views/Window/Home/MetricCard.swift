import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    var caption: String? = nil
    var trend: Trend? = nil

    enum Trend: Equatable {
        case up(String)
        case down(String)
        case flat(String)

        var label: String {
            switch self {
            case .up(let s), .down(let s), .flat(let s): s
            }
        }

        var symbol: String {
            switch self {
            case .up:   LeafIcons.metric.up
            case .down: LeafIcons.metric.down
            case .flat: LeafIcons.metric.flat
            }
        }

        var color: Color {
            switch self {
            case .up:   .leafAccentDeep
            case .down: .leafSignal
            case .flat: .leafMuted
            }
        }
    }

    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .leafLabelStyle()
                Text(value)
                    .font(.leafMetric)
                    .foregroundStyle(.leafInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if caption != nil || trend != nil {
                    HStack(spacing: 8) {
                        if let trend {
                            HStack(spacing: 3) {
                                Image.leafAsset(trend.symbol).frame(width: 11, height: 11)
                                Text(trend.label)
                            }
                            .font(.leafCaption)
                            .foregroundStyle(trend.color)
                        }
                        if let caption {
                            Text(caption)
                                .font(.leafCaption)
                                .foregroundStyle(.leafMuted)
                        }
                    }
                }
            }
        }
    }
}
