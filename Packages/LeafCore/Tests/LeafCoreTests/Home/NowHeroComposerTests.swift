//
//  NowHeroComposerTests.swift
//  Home redesign — NOW hero merges the former RESUME + YOU'RE ON blocks.
//  Locks the composition contract: task line fallbacks, trunk-branch
//  ahead/behind suppression, session/commit/files line pass-through.
//

import XCTest

@testable import LeafCore

final class NowHeroComposerTests: XCTestCase {

  private let calendar = Calendar(identifier: .gregorian)
  private let now = Date(timeIntervalSince1970: 1_765_400_000)

  // MARK: - Task line

  func testTaskLine_linearAndBranchAndRepo() {
    let identity = TaskIdentity(linearID: "GUN-56", branch: "feature/relay", repo: "leaf")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.taskLine, "GUN-56 · feature/relay · leaf")
  }

  func testTaskLine_branchAndRepoOnly() {
    let identity = TaskIdentity(branch: "dev", repo: "leaf")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.taskLine, "dev · leaf")
  }

  func testTaskLine_nilIdentity_returnsNilAndEmpty() {
    let hero = NowHeroComposer.compose(
      taskIdentity: nil, gitDelta: nil, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertNil(hero.taskLine)
    XCTAssertTrue(hero.isEmpty)
  }

  func testTaskLine_repoEqualToBranch_noDuplicate() {
    let identity = TaskIdentity(branch: "leaf", repo: "leaf")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.taskLine, "leaf")
  }

  // MARK: - WIP line / trunk suppression

  func testWipLine_trunkBranch_suppressesAheadBehind() {
    // dev = trunk in our git model; "+87 ahead of main" is structural, not WIP.
    for trunk in ["dev", "main", "master", "develop", "trunk"] {
      let identity = TaskIdentity(branch: trunk)
      let delta = GitDeltaSnapshot(
        commitsAhead: 87, commitsBehind: 0, uncommittedCount: 0, mergeBase: "origin/main")
      let hero = NowHeroComposer.compose(
        taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
        now: now, calendar: calendar)
      XCTAssertNil(hero.wipLine, "trunk branch \(trunk) must not surface ahead/behind")
    }
  }

  func testWipLine_trunkBranch_uncommittedStillShown() {
    let identity = TaskIdentity(branch: "dev")
    let delta = GitDeltaSnapshot(
      commitsAhead: 87, commitsBehind: 2, uncommittedCount: 3, mergeBase: "origin/main")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.wipLine, "3 uncommitted")
  }

  func testWipLine_featureBranch_showsAheadAndUncommitted() {
    let identity = TaskIdentity(branch: "feature/relay")
    let delta = GitDeltaSnapshot(
      commitsAhead: 4, commitsBehind: 0, uncommittedCount: 2, mergeBase: "origin/main")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.wipLine, "2 uncommitted · 4 ahead of main")
  }

  func testWipLine_branchEqualsMergeBaseBasename_suppressed() {
    // Checked out the trunk under a non-standard name matching the merge base.
    let identity = TaskIdentity(branch: "release-2")
    let delta = GitDeltaSnapshot(
      commitsAhead: 12, commitsBehind: 0, uncommittedCount: 0, mergeBase: "origin/release-2")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertNil(hero.wipLine)
  }

  func testWipLine_featureBranch_behindShown() {
    let identity = TaskIdentity(branch: "feature/relay")
    let delta = GitDeltaSnapshot(
      commitsAhead: 0, commitsBehind: 6, uncommittedCount: 0, mergeBase: "origin/main")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.wipLine, "6 behind main")
  }

  func testWipLine_nilBranch_failsQuiet_uncommittedOnly() {
    // Unknown branch must not regress into structural "+87 ahead" noise.
    let delta = GitDeltaSnapshot(
      commitsAhead: 87, commitsBehind: 0, uncommittedCount: 1, mergeBase: "origin/main")
    let hero = NowHeroComposer.compose(
      taskIdentity: TaskIdentity(repo: "leaf"), gitDelta: delta, session: nil,
      whereStopped: nil, now: now, calendar: calendar)
    XCTAssertEqual(hero.wipLine, "1 uncommitted")
  }

  func testIsTrunk_caseInsensitiveOnMergeBaseMatch() {
    XCTAssertTrue(NowHeroComposer.isTrunk(branch: "Release-2", mergeBaseBasename: "release-2"))
    XCTAssertTrue(NowHeroComposer.isTrunk(branch: "Main", mergeBaseBasename: "other"))
    XCTAssertFalse(NowHeroComposer.isTrunk(branch: nil, mergeBaseBasename: "main"))
  }

  func testWipLine_zeroEverything_nil() {
    let identity = TaskIdentity(branch: "feature/relay")
    let delta = GitDeltaSnapshot(
      commitsAhead: 0, commitsBehind: 0, uncommittedCount: 0, mergeBase: "origin/main")
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: delta, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertNil(hero.wipLine)
  }

  // MARK: - Session / commit / files lines

  func testSessionLine_passesThroughComposer() {
    let identity = TaskIdentity(branch: "feature/relay")
    let session = CurrentTaskSession(
      taskIdentity: identity,
      sessionStartMs: 1_765_372_680_000,  // some HH:mm in the calendar TZ
      focusedMinSoFar: 92,
      openFiles: ["A.swift", "B.swift"],
      sessionSource: .ide)
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: session, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(
      hero.sessionLine,
      YoureOnRowComposer.composeSessionLine(
        sessionStartMs: 1_765_372_680_000, focusedMin: 92, now: now, calendar: calendar))
    XCTAssertEqual(hero.filesLine, "Open files: A.swift · B.swift")
  }

  func testSessionLine_fallbackSourceZeroFocus_suppressed() {
    // Fresh DB: CurrentTaskSession falls back to today 00:00 with no focused
    // minutes — "Started 00:00" is synthetic, not a fact. Hide the line.
    let identity = TaskIdentity(branch: "dev")
    let session = CurrentTaskSession(
      taskIdentity: identity, sessionStartMs: 1_765_372_680_000,
      focusedMinSoFar: 0, openFiles: [], sessionSource: .fallback)
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: session, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertNil(hero.sessionLine)
  }

  func testSessionLine_fallbackSourceWithFocus_showsFocusOnly() {
    // Fallback start time is synthetic, but real focused minutes are worth
    // showing — without the misleading "Started 00:00" prefix.
    let identity = TaskIdentity(branch: "dev")
    let session = CurrentTaskSession(
      taskIdentity: identity, sessionStartMs: 1_765_372_680_000,
      focusedMinSoFar: 45, openFiles: [], sessionSource: .fallback)
    let hero = NowHeroComposer.compose(
      taskIdentity: identity, gitDelta: nil, session: session, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.sessionLine, "45m focused so far")
  }

  func testCommitLine_truncatedAt60() {
    let subject = String(repeating: "x", count: 80)
    let stopped = WhereStoppedSnapshot(
      id: 1, generatedAtMs: 0, anchorEventId: nil, excerpt: "", wipSignals: [],
      recentLastCommit: RecentCommitSnapshot(subject: subject, branch: "dev", atMs: 0))
    let hero = NowHeroComposer.compose(
      taskIdentity: TaskIdentity(branch: "dev"), gitDelta: nil, session: nil,
      whereStopped: stopped, now: now, calendar: calendar)
    XCTAssertEqual(hero.commitLine, "Last commit: “\(String(repeating: "x", count: 60))…”")
  }

  func testAnchorLine_fileAndLine() {
    let stopped = WhereStoppedSnapshot(
      id: 1, generatedAtMs: 0, anchorEventId: nil, excerpt: "editing", wipSignals: [],
      anchorFilePath: "HomeView.swift", anchorLine: 42)
    let hero = NowHeroComposer.compose(
      taskIdentity: nil, gitDelta: nil, session: nil, whereStopped: stopped,
      now: now, calendar: calendar)
    XCTAssertEqual(hero.anchorLine, "HomeView.swift:42")
    XCTAssertFalse(hero.isEmpty)
  }

  func testIsEmpty_allInputsNil() {
    let hero = NowHeroComposer.compose(
      taskIdentity: nil, gitDelta: nil, session: nil, whereStopped: nil,
      now: now, calendar: calendar)
    XCTAssertTrue(hero.isEmpty)
  }
}
