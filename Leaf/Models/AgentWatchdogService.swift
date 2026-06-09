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
  static let escalationNotificationID = "leaf.watchdog.escalation"
  static let tickIntervalSec: TimeInterval = 120
  static let firstTickDelaySec: TimeInterval = 60

  private let launchAgent: LaunchAgentService
  private let logger = Logger(subsystem: "tech.gundem.leaf", category: "watchdog")
  private var loop: Task<Void, Never>?
  private var state: WatchdogState
  /// MainActor-reentrancy guard: tick() and repairNow() interleave on
  /// suspension points; only one recovery sequence may run at a time
  /// (a tick mid-repair would kickstart-SIGKILL the agent the repair just
  /// brought up and corrupt the repair verdict).
  private var recoveryInFlight = false
  /// Wall-clock of the previous tick — a gap far beyond the interval means
  /// the Mac slept; the first post-wake tick is skipped so a heartbeat that
  /// is merely "old because we slept" doesn't get a spurious kickstart.
  private var lastTickAt: Date?

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
    // Escape hatch for dev flows that deliberately kill/replace agents
    // (set to any non-empty value).
    if let disabled = ProcessInfo.processInfo.environment[Self.disableEnvKey], !disabled.isEmpty {
      logger.info("watchdog disabled via \(Self.disableEnvKey, privacy: .public)")
      return
    }
    loop = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.firstTickDelaySec * 1_000_000_000))
      while !Task.isCancelled {
        guard let self else { break }
        await self.tick()
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
    guard !recoveryInFlight else { return }
    // Post-wake detection: a tick gap far beyond the interval means the Mac
    // slept and the heartbeat is stale only because nothing ran. Skip one
    // tick to give the agent its 30s write window instead of SIGKILLing a
    // healthy process.
    let now = Date()
    let previousTick = lastTickAt
    lastTickAt = now
    if let previousTick, now.timeIntervalSince(previousTick) > Self.tickIntervalSec * 2 {
      logger.info("tick skipped after sleep gap of \(Int(now.timeIntervalSince(previousTick)), privacy: .public)s")
      return
    }

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
      } else if !input.intentEnabled {
        // The user deliberately turned collection off — a leftover
        // escalation banner is no longer actionable.
        escalation = nil
      }

    case .kickstart:
      recoveryInFlight = true
      defer { recoveryInFlight = false }
      persist(state.recordingAttempt(at: input.now, wasReregister: false))
      await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)

    case .reregisterThenKickstart:
      recoveryInFlight = true
      defer { recoveryInFlight = false }
      persist(state.recordingAttempt(at: input.now, wasReregister: true))
      // register() from the installed copy re-points a hijacked BTM parent
      // record back at this bundle. Success is judged by a fresh heartbeat
      // on a later tick, never by register()'s own result (the "already
      // registered" case is a silent filtered no-op).
      launchAgent.register()
      await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)

    case .awaitApproval(let escalate):
      if escalate {
        persist(state.recordingApprovalEscalation())
        surfaceEscalation(
          message:
            "Leaf needs approval in System Settings → General → Login Items to resume background collection.",
          needsLoginItemsApproval: true)
      }

    case .escalate:
      persist(state.recordingFailureEscalation())
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
  /// Note: register() flips the intent flag ON — deliberate; clicking Repair
  /// means "make collection work".
  func repairNow() async {
    guard !recoveryInFlight else { return }
    guard launchAgent.shouldAutoRegister else {
      // Registering from a non-canonical copy would hijack the BTM record —
      // the exact failure this track fixes. Don't offer a footgun.
      logger.warning("manual repair refused: non-canonical bundle location")
      surfaceEscalation(
        message:
          "Leaf is running from \(Bundle.main.bundleURL.path). Move it to /Applications and relaunch before repairing background collection.",
        needsLoginItemsApproval: false)
      return
    }
    recoveryInFlight = true
    defer { recoveryInFlight = false }
    logger.info("manual repair requested")
    escalation = nil
    persist(WatchdogState.initial)
    let repairStartMs = Int64(Date().timeIntervalSince1970 * 1000)

    launchAgent.register()
    await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)
    if await Self.awaitHeartbeat(newerThanMs: repairStartMs, timeoutSec: 25) {
      logger.info("manual repair: fresh heartbeat after register+kickstart")
      return
    }
    logger.warning("manual repair: escalating to unregister+register")
    launchAgent.unregister()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    launchAgent.register()
    await Self.kickstart(label: LaunchAgentService.agentLabel, logger: logger)
    if await Self.awaitHeartbeat(newerThanMs: repairStartMs, timeoutSec: 25) {
      logger.info("manual repair: fresh heartbeat after unregister+register")
    } else {
      logger.error("manual repair: agent still silent — surfacing escalation")
      surfaceEscalation(
        message:
          "Repair didn't bring the agent back. Open System Settings → General → Login Items and toggle Leaf OFF, wait 3 seconds, then ON.",
        needsLoginItemsApproval: true)
    }
  }

  /// Polls for a heartbeat written AFTER the repair started — absolute
  /// staleness would call a pre-repair heartbeat a success and a slow cold
  /// start (SQLCipher open + migrations precede the first write) a failure.
  private nonisolated static func awaitHeartbeat(
    newerThanMs: Int64, timeoutSec: TimeInterval
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
      if let hb = DebugHeartbeat.read(), hb.tsMs >= newerThanMs { return true }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
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
      identifier: Self.escalationNotificationID,
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
