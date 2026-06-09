// Agent watchdog track — pure recovery decision policy.
// Key case (live hijack): the stale heartbeat was written by the last healthy
// agent run, so its bundlePath MATCHES the expected one — the crash-loop
// signature from launchctl print is what must trigger re-register, not the
// heartbeat fields. Never decides automatic unregister+register cycles
// (Sequoia BTM desync backfire); re-register only, only from a canonical
// location, on a long cooldown.

import XCTest

@testable import LeafCore

final class AgentWatchdogPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_781_000_000)
  private let installedPath = "/Applications/Leaf.app"

  private func input(
    intent: Bool = true,
    status: AgentServiceStatus = .enabled,
    heartbeatAgeSec: TimeInterval? = 7_200,
    heartbeatBundlePath: String? = "/Applications/Leaf.app",
    heartbeatEverExisted: Bool = true,
    jobInfo: AgentJobInfo? = nil,
    isCanonical: Bool = true
  ) -> WatchdogInput {
    WatchdogInput(
      intentEnabled: intent,
      status: status,
      heartbeatAgeSec: heartbeatAgeSec,
      heartbeatBundlePath: heartbeatBundlePath,
      heartbeatEverExisted: heartbeatEverExisted,
      jobInfo: jobInfo,
      expectedBundlePath: installedPath,
      isCanonicalLocation: isCanonical,
      now: now
    )
  }

  private let crashLoopJob = AgentJobInfo(state: "spawn scheduled", runs: 2521, lastExitCode: 78)
  private let healthyJob = AgentJobInfo(state: "running", runs: 3, lastExitCode: 0)

  // MARK: - Silence

  func testIntentOffIsAlwaysSilent() {
    let decision = AgentWatchdogPolicy.decide(
      input(intent: false, status: .notRegistered, jobInfo: crashLoopJob),
      state: .initial)
    XCTAssertEqual(decision, .none)
  }

  func testFreshHeartbeatIsSilent() {
    let decision = AgentWatchdogPolicy.decide(
      input(heartbeatAgeSec: 31), state: .initial)
    XCTAssertEqual(decision, .none)
  }

  // MARK: - Kickstart (plain dead agent)

  func testStaleHeartbeatEnabledStatusKickstarts() {
    let decision = AgentWatchdogPolicy.decide(
      input(jobInfo: healthyJob), state: .initial)
    XCTAssertEqual(decision, .kickstart)
  }

  func testMissingHeartbeatEnabledStatusKickstarts() {
    let decision = AgentWatchdogPolicy.decide(
      input(heartbeatAgeSec: nil, heartbeatBundlePath: nil, heartbeatEverExisted: false),
      state: .initial)
    XCTAssertEqual(decision, .kickstart)
  }

  func testRateLimitSuppressesRepeatAttempt() {
    let state = WatchdogState.initial.recordingAttempt(at: now.addingTimeInterval(-300), wasReregister: false)
    XCTAssertEqual(AgentWatchdogPolicy.decide(input(jobInfo: healthyJob), state: state), .none)
  }

  func testAttemptAllowedAfterCooldown() {
    let state = WatchdogState.initial.recordingAttempt(at: now.addingTimeInterval(-660), wasReregister: false)
    XCTAssertEqual(AgentWatchdogPolicy.decide(input(jobInfo: healthyJob), state: state), .kickstart)
  }

  // MARK: - Hijack signature → re-register (F1)

  func testCrashLoopWithMatchingHeartbeatPathReregisters() {
    // The live case: heartbeat bundlePath matches /Applications, status may
    // read .enabled — only the crash loop betrays the hijacked BTM record.
    let decision = AgentWatchdogPolicy.decide(
      input(jobInfo: crashLoopJob), state: .initial)
    XCTAssertEqual(decision, .reregisterThenKickstart)
  }

  func testHeartbeatBundlePathMismatchReregisters() {
    let decision = AgentWatchdogPolicy.decide(
      input(heartbeatBundlePath: "/tmp/LeafDbg.xcarchive/Products/Applications/Leaf.app"),
      state: .initial)
    XCTAssertEqual(decision, .reregisterThenKickstart)
  }

  func testNotRegisteredStatusReregisters() {
    let decision = AgentWatchdogPolicy.decide(
      input(status: .notRegistered), state: .initial)
    XCTAssertEqual(decision, .reregisterThenKickstart)
  }

  func testHijackFromNonCanonicalLocationOnlyKickstarts() {
    let decision = AgentWatchdogPolicy.decide(
      input(jobInfo: crashLoopJob, isCanonical: false), state: .initial)
    XCTAssertEqual(decision, .kickstart)
  }

  func testReregisterCooldownFallsBackToKickstart() {
    let state = WatchdogState.initial
      .recordingAttempt(at: now.addingTimeInterval(-1200), wasReregister: true)
    XCTAssertEqual(
      AgentWatchdogPolicy.decide(input(jobInfo: crashLoopJob), state: state),
      .kickstart)
  }

  // MARK: - Approval gate

  func testRequiresApprovalEscalatesOnceWhenAgentEverLived() {
    let first = AgentWatchdogPolicy.decide(
      input(status: .requiresApproval), state: .initial)
    XCTAssertEqual(first, .awaitApproval(escalate: true))

    let escalatedState = WatchdogState.initial.recordingApprovalEscalation()
    let second = AgentWatchdogPolicy.decide(
      input(status: .requiresApproval), state: escalatedState)
    XCTAssertEqual(second, .awaitApproval(escalate: false))
  }

  func testApprovalEscalationDoesNotSwallowFailureEscalation() {
    // Episode starts as requiresApproval (escalated once), the user approves,
    // the agent is still dead → after max failed attempts the SEPARATE
    // failure escalation must still fire (shared latch would return .none
    // forever and the "use Repair" notification would never arrive).
    var state = WatchdogState.initial.recordingApprovalEscalation()
    for i in 0..<AgentWatchdogPolicy.maxAttemptsBeforeEscalation {
      state = state.recordingAttempt(
        at: now.addingTimeInterval(TimeInterval(-3600 + i * 660)), wasReregister: false)
    }
    XCTAssertEqual(
      AgentWatchdogPolicy.decide(input(jobInfo: healthyJob), state: state),
      .escalate)
  }

  func testRequiresApprovalSilentOnFirstRun() {
    // Onboarding: Login Items not approved yet, agent never produced a
    // heartbeat — no notification spam (F4).
    let decision = AgentWatchdogPolicy.decide(
      input(
        status: .requiresApproval, heartbeatAgeSec: nil,
        heartbeatBundlePath: nil, heartbeatEverExisted: false),
      state: .initial)
    XCTAssertEqual(decision, .awaitApproval(escalate: false))
  }

  // MARK: - Escalation after repeated failures

  func testEscalatesAfterMaxFailedAttempts() {
    var state = WatchdogState.initial
    for i in 0..<AgentWatchdogPolicy.maxAttemptsBeforeEscalation {
      state = state.recordingAttempt(
        at: now.addingTimeInterval(TimeInterval(-3600 + i * 660)), wasReregister: false)
    }
    XCTAssertEqual(
      AgentWatchdogPolicy.decide(input(jobInfo: healthyJob), state: state),
      .escalate)
  }

  func testEscalatesExactlyOnce() {
    var state = WatchdogState.initial
    for i in 0..<AgentWatchdogPolicy.maxAttemptsBeforeEscalation {
      state = state.recordingAttempt(
        at: now.addingTimeInterval(TimeInterval(-3600 + i * 660)), wasReregister: false)
    }
    state = state.recordingFailureEscalation()
    XCTAssertEqual(
      AgentWatchdogPolicy.decide(input(jobInfo: healthyJob), state: state),
      .none)
  }

  // MARK: - State lifecycle

  func testHealthyTickResetsState() {
    var state = WatchdogState.initial
      .recordingAttempt(at: now, wasReregister: true)
      .recordingAttempt(at: now, wasReregister: false)
      .recordingApprovalEscalation()
      .recordingFailureEscalation()
    state = state.recordingHealthy()
    XCTAssertEqual(state, .initial)
  }

  func testAttemptRecordingCountsFailuresAndTimestamps() {
    let state = WatchdogState.initial
      .recordingAttempt(at: now, wasReregister: true)
    XCTAssertEqual(state.consecutiveFailures, 1)
    XCTAssertEqual(state.lastAttemptAt, now)
    XCTAssertEqual(state.lastReregisterAt, now)

    let next = state.recordingAttempt(at: now.addingTimeInterval(660), wasReregister: false)
    XCTAssertEqual(next.consecutiveFailures, 2)
    XCTAssertEqual(next.lastReregisterAt, now)
  }

  func testStateCodableRoundTrip() throws {
    let state = WatchdogState.initial
      .recordingAttempt(at: now, wasReregister: true)
      .recordingFailureEscalation()
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WatchdogState.self, from: data)
    XCTAssertEqual(decoded, state)
  }
}
