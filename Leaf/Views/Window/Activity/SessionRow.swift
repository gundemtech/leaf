import SwiftUI
import LeafCore

/// Phase 4.10.B — одна строка списка сессий: real app icon, colored category dot,
/// app name, window/file/URL context, duration.
struct SessionRow: View {
    let session: ActivitySession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconView
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.leafCategory(session.category))
                        .frame(width: 6, height: 6)
                    Text(AppNameResolver.shared.displayName(for: session.bundleID))
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                        .lineLimit(1)
                }
                if let context = session.contextLabel,
                   !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(context)
                        .font(.leafCaption)
                        .foregroundStyle(.leafMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(formatDuration(session.duration))
                .font(.leafCaption.monospacedDigit())
                .foregroundStyle(.leafMuted)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        #if os(macOS)
        if let nsImage = AppIconResolver.shared.icon(for: session.bundleID, size: 32) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            fallbackIcon
        }
        #else
        fallbackIcon
        #endif
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.leafCategory(session.category).opacity(0.18))
            Image(systemName: "app.dashed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.leafCategory(session.category))
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
}
