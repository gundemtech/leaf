import Foundation
import os

// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor → globals are MainActor-isolated by default.
// Explicit `nonisolated` so Logger is reachable from actors (EventWriter) without hops.
// Logger is Sendable, so `unsafe` is not needed.

/// Subsystem for the whole Agent. Viewable in Console.app → filter by subsystem.
nonisolated let agentLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "core")
nonisolated let collectorLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "collectors")
nonisolated let writerLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "writer")
nonisolated let maintenanceLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "maintenance")
nonisolated let claudeCodeLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "claude-code")
nonisolated let fsEventsLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "fsevents")
nonisolated let linearLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "linear-collector")
nonisolated let githubLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "github-collector")
nonisolated let slackLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "slack-collector")
nonisolated let detectorLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "detectors")
