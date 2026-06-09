import Foundation

/// Mirror of SMAppService.Status so the policy stays free of
/// ServiceManagement (and unit-testable in the SPM package).
public enum AgentServiceStatus: Sendable, Equatable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
  case unknown
}

/// Everything the watchdog policy needs for one tick, gathered by the app.
public struct WatchdogInput: Sendable {
  public let intentEnabled: Bool
  public let status: AgentServiceStatus
  /// nil — heartbeat file absent/unreadable.
  public let heartbeatAgeSec: TimeInterval?
  public let heartbeatBundlePath: String?
  /// The agent produced a heartbeat at least once on this machine. Gates the
  /// requiresApproval escalation so onboarding (Login Items not approved yet)
  /// doesn't trigger notifications.
  public let heartbeatEverExisted: Bool
  public let jobInfo: AgentJobInfo?
  public let expectedBundlePath: String
  public let isCanonicalLocation: Bool
  public let now: Date

  public init(
    intentEnabled: Bool,
    status: AgentServiceStatus,
    heartbeatAgeSec: TimeInterval?,
    heartbeatBundlePath: String?,
    heartbeatEverExisted: Bool,
    jobInfo: AgentJobInfo?,
    expectedBundlePath: String,
    isCanonicalLocation: Bool,
    now: Date
  ) {
    self.intentEnabled = intentEnabled
    self.status = status
    self.heartbeatAgeSec = heartbeatAgeSec
    self.heartbeatBundlePath = heartbeatBundlePath
    self.heartbeatEverExisted = heartbeatEverExisted
    self.jobInfo = jobInfo
    self.expectedBundlePath = expectedBundlePath
    self.isCanonicalLocation = isCanonicalLocation
    self.now = now
  }
}

/// Persisted across app relaunches (UserDefaults) so rate limits and the
/// escalate-once latch survive restarts. Reset by the first healthy tick.
public struct WatchdogState: Codable, Sendable, Equatable {
  public var lastAttemptAt: Date?
  public var lastReregisterAt: Date?
  public var consecutiveFailures: Int
  /// Separate latches: an approval episode that escalated must not swallow a
  /// later "recovery attempts exhausted" escalation (and vice versa). Both
  /// reset on the first healthy tick.
  public var approvalEscalated: Bool
  public var failureEscalated: Bool

  public static let initial = WatchdogState(
    lastAttemptAt: nil, lastReregisterAt: nil, consecutiveFailures: 0,
    approvalEscalated: false, failureEscalated: false)

  public func recordingAttempt(at now: Date, wasReregister: Bool) -> WatchdogState {
    var next = self
    next.lastAttemptAt = now
    if wasReregister { next.lastReregisterAt = now }
    next.consecutiveFailures += 1
    return next
  }

  public func recordingHealthy() -> WatchdogState { .initial }

  public func recordingApprovalEscalation() -> WatchdogState {
    var next = self
    next.approvalEscalated = true
    return next
  }

  public func recordingFailureEscalation() -> WatchdogState {
    var next = self
    next.failureEscalated = true
    return next
  }
}

public enum WatchdogDecision: Sendable, Equatable {
  case none
  case kickstart
  /// register() (re-points the hijacked BTM parent record back to this
  /// bundle) followed by kickstart. NEVER an unregister+register cycle —
  /// that worsens the Sequoia BTM desync.
  case reregisterThenKickstart
  /// Login Items approval pending; `escalate` = surface the banner +
  /// notification this tick (once per broken episode).
  case awaitApproval(escalate: Bool)
  /// Recovery attempts exhausted — surface the banner + notification.
  case escalate
}

/// Pure decision core of the agent watchdog. "Success" of a prior attempt is
/// never inferred from API results (register() may be a silent filtered
/// "already registered" no-op) — only a fresh heartbeat on a later tick
/// counts, which is why failures reset exclusively via recordingHealthy().
public enum AgentWatchdogPolicy {
  /// Mirrors DebugHeartbeat.isStale default (30s writes × 4 headroom).
  public static let staleThresholdSec: TimeInterval = 120
  /// Minimum spacing between recovery attempts.
  public static let attemptCooldownSec: TimeInterval = 600
  /// Re-pointing the BTM record is rarer than a plain kickstart.
  public static let reregisterCooldownSec: TimeInterval = 1800
  public static let maxAttemptsBeforeEscalation = 3

  public static func decide(_ input: WatchdogInput, state: WatchdogState) -> WatchdogDecision {
    guard input.intentEnabled else { return .none }

    if let age = input.heartbeatAgeSec, age <= staleThresholdSec {
      return .none  // healthy; the caller resets state via recordingHealthy()
    }

    if input.status == .requiresApproval {
      let shouldEscalate = input.heartbeatEverExisted && !state.approvalEscalated
      return .awaitApproval(escalate: shouldEscalate)
    }

    if state.consecutiveFailures >= maxAttemptsBeforeEscalation {
      return state.failureEscalated ? .none : .escalate
    }

    if let last = state.lastAttemptAt, input.now.timeIntervalSince(last) < attemptCooldownSec {
      return .none
    }

    let hijackSignature =
      input.status != .enabled
      || (input.heartbeatBundlePath != nil && input.heartbeatBundlePath != input.expectedBundlePath)
      || (input.jobInfo?.isCrashLooping ?? false)

    if hijackSignature, input.isCanonicalLocation {
      let reregisterAllowed =
        state.lastReregisterAt.map {
          input.now.timeIntervalSince($0) >= reregisterCooldownSec
        } ?? true
      if reregisterAllowed { return .reregisterThenKickstart }
    }
    return .kickstart
  }
}
