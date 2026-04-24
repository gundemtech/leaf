import Foundation

/// Короткий формат длительности: `"1h 42m"` / `"12m"` / `"30s"`.
///
/// Не используем `DateComponentsFormatter` намеренно — он локаль-зависим
/// ("1 hr 42 min") и медленнее. Этот формат — фиксированный, для UI popover'а
/// и MCP tool responses.
public func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total >= 3600 {
        let h = total / 3600
        let m = (total % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
    if total >= 60 {
        return "\(total / 60)m"
    }
    return "\(total)s"
}
