import Foundation
import os

// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor → globals по умолчанию MainActor-isolated.
// Явный `nonisolated` чтобы Logger был доступен из actor'ов (EventWriter) без hop'ов.
// Logger is Sendable, поэтому `unsafe` не нужен.

/// Subsystem для всего Agent'а. Viewable в Console.app → filter by subsystem.
nonisolated let agentLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "core")
nonisolated let collectorLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "collectors")
nonisolated let writerLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "writer")
nonisolated let maintenanceLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "maintenance")
nonisolated let claudeCodeLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "claude-code")
nonisolated let fsEventsLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "fsevents")
nonisolated let linearLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "linear-collector")
nonisolated let githubLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "github-collector")
nonisolated let slackLogger = Logger(subsystem: "tech.gundem.leaf.agent", category: "slack-collector")
