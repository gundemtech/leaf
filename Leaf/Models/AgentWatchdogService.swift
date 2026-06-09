//
//  AgentWatchdogService.swift
//  Leaf
//
//  Process-lifetime self-heal loop for the capture agent. Before this the
//  heartbeat file was read only when the user opened Settings → Diagnostics,
//  so a dead agent (crashed, BTM record hijacked by a copy registered from
//  /tmp, crash-looping with EX_CONFIG) stayed dead until the user manually
//  re-toggled Login Items / the collection toggle.
//
//  Decision-making lives in LeafCore.AgentWatchdogPolicy (pure, unit-tested);
//  this service only gathers inputs and executes decisions. Started from
//  applicationDidFinishLaunching — NOT window-scoped, the loop must outlive
//  closed windows in a menubar app.
//

import Foundation
import LeafCore
import ServiceManagement
import SwiftUI
import UserNotifications
import os

@MainActor
@Observable
final class AgentWatchdogService {
  struct Escalation: Equatable {
    let title: String
    let message: String
    let needsLoginItemsApproval: Bool
  }

  /// Surfaced by Settings UI as a persistent banner; cleared by a healthy tick.
  private(set) var escalation: Escalation?
  /// Last `launchctl print` snapshot — reused by Diagnostics.
  private(set) var lastJobInfo: AgentJobInfo?

  static let stateDefaultsKey = "agentWatchdogState"
  static let disableEnvKey = "LEAF_DISABLE_WATCHDOG"
  static let tickIntervalSec: TimeInterval = 120
  static let firstTickDelaySec: TimeInterval = 60

  private let launchAgent: LaunchAgentService
  private let logger = Logger(subsystem: "tech.gundem.leaf", category: "watchdog")
  private var loop: Task<Void, Never>?
  private var state: WatchdogState

  init(launchAgent: LaunchAgentService) {
    self.launchAgent = launchAgent
    if let data = UserDefaults.standard.data(forKey: Self.stateDefaultsKey),
      let saved = try? JSONDecoder().decode(WatchdogState.self, from: data)
    {
      state = saved
    } else {
      state = .initial
    }
  }

  func start() {
    guard loop == nil else { return }
    // Dev scripts (just dev / dev-clean) deliberately kill agents mid-flow;
    // the escape hatch keeps the watchdog from fighting them.
    if let disabled = ProcessInfo.processInfo.environment[Self.disableEnvKey], !disabled.isEmpty {
      logger.info("watchdog disabled via \(Self.disableEnvKey, privacy: .public)")
      return
    }
    loop = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.firstTickDelaySec * 1_000_000_000))
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(nanoseconds: UInt64(Self.tickIntervalSec * 1_000_000_000))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  // MARK: - Tick

  func tick() async {
    launchAgent.refreshStatus()
    let input = await Self.gatherInput(
      intentEnabled: launchAgent.intentEnabled,
      status: Self.mirror(launchAgent.status),
      expectedBundlePath: Bundle.main.bundleURL.path,
      isCanonical: launchAgent.isCanonicalLocation,
      label: LaunchAgentService.agentLabel)
    lastJobInfo = input.jobInfo

    let decision = AgentWatchdogPolicy.decide(input, state: state)
    let isFresh =
      input.heartbeatAgeSec.map { $0 <= AgentWatchdogPolicy.staleThresholdSec } ?? false
    logger.info(
      "tick decision=\(String(describing: decision), privacy: .public) status=\(String(describing: input.status), privacy: .public) hbAge=\(input.heartbeatAgeSec.map { String(Int($0)) } ?? "nil", privacy: .public) job=\(input.jobInfo.map(String.init(describing:)) ?? "nil", privacy: .public)")

    switch decision {
    case .none:
      if isFresh {
        if state != .initial { persist(state.recordingHealthy()) }
        escalation = nil
      }

    case .kickstart:
      persist(state.recordingAttempt(at: input.now, wasReregister: false))
      await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)

    case .reregisterThenKickstart:
      persist(state.recordingAttempt(at: input.now, wasReregister: true))
      // register() from the installed copy re-points a hijacked BTM parent
      // record back at this bundle. Success is judged by a fresh heartbeat
      // on a later tick, never by register()'s own result (the "already
      // registered" case is a silent filtered no-op).
      launchAgent.register()
      await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)

    case .awaitApproval(let escalate):
      if escalate {
        persist(state.recordingEscalation())
        surfaceEscalation(
          message:
            "Leaf needs approval in System Settings → General → Login Items to resume background collection.",
          needsLoginItemsApproval: true)
      }

    case .escalate:
      persist(state.recordingEscalation())
      surfaceEscalation(
        message:
          "Background collection stopped and automatic recovery didn't help. Open Leaf Settings → Diagnostics and use Repair.",
        needsLoginItemsApproval: false)
    }
  }

  /// Manual repair from Settings → Diagnostics. User-initiated, so it may go
  /// one step further than the automatic loop: if register+kickstart doesn't
  /// revive the heartbeat, do a one-time unregister+register (the documented
  /// manual remedy for a disabled/hijacked BTM record — safe as a deliberate
  /// single action, harmful only as an automatic every-launch cycle).
  func repairNow() async {
    logger.info("manual repair requested")
    escalation = nil
    persist(WatchdogState.initial)

    launchAgent.register()
    await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)
    try? await Task.sleep(nanoseconds: 5_000_000_000)

    if let hb = DebugHeartbeat.read(), !hb.isStale() {
      logger.info("manual repair: heartbeat fresh after register+kickstart")
      return
    }
    logger.warning("manual repair: escalating to unregister+register")
    let intent = launchAgent.intentEnabled
    launchAgent.unregister()
    launchAgent.intentEnabled = intent  // unregister() clears it; restore user intent
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    launchAgent.register()
    await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)
  }

  // MARK: - Input gathering (blocking IO off the main actor)

  private nonisolated static func gatherInput(
    intentEnabled: Bool,
    status: AgentServiceStatus,
    expectedBundlePath: String,
    isCanonical: Bool,
    label: String
  ) async -> WatchdogInput {
    await Task.detached(priority: .utility) {
      let heartbeatURL = DebugHeartbeat.defaultURL()
      let heartbeat = DebugHeartbeat.read(from: heartbeatURL)
      let everExisted = FileManager.default.fileExists(atPath: heartbeatURL.path)
      let jobInfo = LaunchdJobInfoParser.currentJobInfo(label: label)
      return WatchdogInput(
        intentEnabled: intentEnabled,
        status: status,
        heartbeatAgeSec: heartbeat?.ageSec,
        heartbeatBundlePath: heartbeat?.bundlePath,
        heartbeatEverExisted: everExisted,
        jobInfo: jobInfo,
        expectedBundlePath: expectedBundlePath,
        isCanonicalLocation: isCanonical,
        now: Date()
      )
    }.value
  }

  private nonisolated static func kickstart(label: String, logger: Logger) async {
    await Task.detached(priority: .utility) {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
      task.standardOutput = Pipe()
      task.standardError = Pipe()
      do {
        // -k sends SIGKILL to a live instance — acceptable: the agent is
        // presumed dead, the DB is WAL crash-safe, at most one unflushed
        // event batch is lost.
        try task.run()
        task.waitUntilExit()
        logger.info("kickstart exit=\(task.terminationStatus, privacy: .public)")
      } catch {
        logger.error("kickstart failed to run: \(error.localizedDescription, privacy: .public)")
      }
    }.value
  }

  // MARK: - Escalation surfaces

  private func surfaceEscalation(message: String, needsLoginItemsApproval: Bool) {
    let title = "Background collection stopped"
    escalation = Escalation(
      title: title, message: message, needsLoginItemsApproval: needsLoginItemsApproval)

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    let request = UNNotificationRequest(
      identifier: "leaf.watchdog.escalation",
      content: content,
      trigger: nil)
    UNUserNotificationCenter.current().add(request)
    logger.error("escalation surfaced: \(message, privacy: .public)")
  }

  private func persist(_ newState: WatchdogState) {
    state = newState
    if let data = try? JSONEncoder().encode(newState) {
      UserDefaults.standard.set(data, forKey: Self.stateDefaultsKey)
    }
  }

  private static func mirror(_ status: SMAppService.Status) -> AgentServiceStatus {
    switch status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .notRegistered
    case .notFound: .notFound
    @unknown default: .unknown
    }
  }
}
