import Foundation

/// Short duration format: `"1h 42m"` / `"12m"` / `"30s"`.
///
/// We deliberately avoid `DateComponentsFormatter` — it's locale-dependent
/// ("1 hr 42 min") and slower. This format is fixed, for the UI popover
/// and MCP tool responses.
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
