import Foundation

/// Phase 4.6 — generic latency distribution для derived metrics поверх timestamp-pair'ов
/// (PR cycle = closed_at - created_at, review delay = review.submitted_at - pr.created_at,
/// huddle session length, Linear completion duration). Все значения в seconds; producer
/// гарантирует non-negative (clamp clock-skew к 0 perform'ится upstream).
public struct LatencyStats: Sendable, Hashable, Codable {
    public let medianSeconds: Int
    public let avgSeconds: Int
    public let maxSeconds: Int
    public let sampleCount: Int

    public init(medianSeconds: Int, avgSeconds: Int, maxSeconds: Int, sampleCount: Int) {
        self.medianSeconds = medianSeconds
        self.avgSeconds = avgSeconds
        self.maxSeconds = maxSeconds
        self.sampleCount = sampleCount
    }

    /// Empty sample → `nil` returned upstream вместо zero-stats — отличаем "не знаем"
    /// от "знаем, но 0 samples". UI/MCP интерпретируют `nil` как hidden.
    public static func from(samples: [Int]) -> LatencyStats? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let count = sorted.count
        let total = sorted.reduce(0, +)
        let avg = Int((Double(total) / Double(count)).rounded())
        let median: Int = {
            if count % 2 == 1 {
                return sorted[count / 2]
            } else {
                let lo = sorted[count / 2 - 1]
                let hi = sorted[count / 2]
                return Int((Double(lo + hi) / 2.0).rounded())
            }
        }()
        return LatencyStats(
            medianSeconds: median,
            avgSeconds: avg,
            maxSeconds: sorted.last ?? 0,
            sampleCount: count
        )
    }
}
