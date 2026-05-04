import SwiftUI
import LeafCore

/// Цветные dots для category badge'й в SessionRow / Recent Sessions.
/// Phase 4.10.B — пять категорий из `AppCategoryClassifier`.
extension Color {
    static func leafCategory(_ category: AppCategory) -> Color {
        switch category {
        case .dev:           return .leafAccentDeep
        case .browse:        return .blue
        case .communication: return .purple
        case .design:        return .orange
        case .other:         return .leafMuted
        }
    }
}
