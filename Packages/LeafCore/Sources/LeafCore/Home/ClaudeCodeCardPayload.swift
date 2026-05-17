//  ClaudeCodeCardPayload.swift
//  Track 7 P1 — typed carrier for SurfaceCardState.enabledPopulated on the
//  Claude Code surface. Spec §4.3: headline = tokens, sub-stats = tool calls
//  + sessions, spark = 7-day daily token sum.

import Foundation

public struct ClaudeCodeCardPayload: Equatable, Sendable {
    public let tokensTotal: Int
    public let toolCallsCount: Int
    public let sessionCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet
    /// computed"; the view renders nothing in that case rather than a
    /// degenerate single-point shape (LeafSparkline already skips < 2
    /// points gracefully).
    public let dailyTokens: [Double]

    public init(
        tokensTotal: Int,
        toolCallsCount: Int,
        sessionCount: Int,
        dailyTokens: [Double]
    ) {
        self.tokensTotal = tokensTotal
        self.toolCallsCount = toolCallsCount
        self.sessionCount = sessionCount
        self.dailyTokens = dailyTokens
    }
}
