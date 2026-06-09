// Agent watchdog track — `launchctl print gui/<uid>/<label>` parser.
// The crash-loop signature (last exit code != 0 + state "spawn scheduled")
// is the only reliable hijacked-BTM-record signal: the stale heartbeat still
// carries the last healthy bundle path, and the printed program identifier is
// parent-relative, so neither exposes the wrong parent URL.

import XCTest

@testable import LeafCore

final class LaunchdJobInfoParserTests: XCTestCase {
  // Captured from a live hijacked record (runs/exit values real).
  private let crashLoopFixture = """
    gui/501/tech.gundem.leaf.agent = {
    \tactive count = 0
    \tpath = (submitted by smd.24504)
    \ttype = Submitted
    \tstate = spawn scheduled

    \tprogram identifier = Contents/MacOS/LeafAgent (mode: 2)
    \tparent bundle identifier = tech.gundem.leaf
    \tdomain = gui/501 [100024]
    \tminimum runtime = 10
    \texit timeout = 5
    \truns = 2521
    \tlast exit code = 78: EX_CONFIG

    \tsemaphores = {
    \t\tsuccessful exit => 0
    \t}
    }
    """

  private let healthyFixture = """
    gui/501/tech.gundem.leaf.agent = {
    \tactive count = 1
    \tstate = running
    \tprogram identifier = Contents/MacOS/LeafAgent (mode: 2)
    \tpid = 31932
    \truns = 3
    \tlast exit code = 0
    }
    """

  private let neverExitedFixture = """
    gui/501/tech.gundem.leaf.agent = {
    \tstate = running
    \truns = 1
    \tlast exit code = (never exited)
    }
    """

  func testParsesCrashLoopFixture() {
    let info = LaunchdJobInfoParser.parse(crashLoopFixture)
    XCTAssertEqual(info?.state, "spawn scheduled")
    XCTAssertEqual(info?.runs, 2521)
    XCTAssertEqual(info?.lastExitCode, 78)
    XCTAssertEqual(info?.isCrashLooping, true)
  }

  func testParsesHealthyFixture() {
    let info = LaunchdJobInfoParser.parse(healthyFixture)
    XCTAssertEqual(info?.state, "running")
    XCTAssertEqual(info?.runs, 3)
    XCTAssertEqual(info?.lastExitCode, 0)
    XCTAssertEqual(info?.isCrashLooping, false)
  }

  func testNeverExitedHasNilExitCodeAndIsNotCrashLooping() {
    let info = LaunchdJobInfoParser.parse(neverExitedFixture)
    XCTAssertEqual(info?.state, "running")
    XCTAssertNil(info?.lastExitCode)
    XCTAssertEqual(info?.isCrashLooping, false)
  }

  func testNonZeroExitWhileRunningIsNotCrashLooping() {
    // A past non-zero exit with a now-running job is recovery, not a loop.
    let fixture = "\tstate = running\n\truns = 7\n\tlast exit code = 78: EX_CONFIG\n"
    let info = LaunchdJobInfoParser.parse(fixture)
    XCTAssertEqual(info?.isCrashLooping, false)
  }

  func testJobNotFoundReturnsNil() {
    let output = """
      Bad request.
      Could not find service "tech.gundem.leaf.agent" in domain for user gui: 501
      """
    XCTAssertNil(LaunchdJobInfoParser.parse(output))
  }

  func testGarbageReturnsNil() {
    XCTAssertNil(LaunchdJobInfoParser.parse(""))
    XCTAssertNil(LaunchdJobInfoParser.parse("lorem ipsum\ndolor = sit amet"))
  }
}
