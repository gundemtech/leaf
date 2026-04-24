import Foundation

/// Уровень детализации того, что команда может увидеть о юзере.
/// L6 (content) отсутствует намеренно — запрещено навсегда (ADR Won't-list).
public enum Granularity: Int, Codable, Sendable, CaseIterable, Comparable {
    case l1 = 1
    case l2 = 2
    case l3 = 3
    case l4 = 4
    case l5 = 5

    public static func < (lhs: Granularity, rhs: Granularity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
