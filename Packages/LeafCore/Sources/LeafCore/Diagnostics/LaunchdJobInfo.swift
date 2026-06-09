import Foundation

/// Snapshot of the agent job from `launchctl print gui/<uid>/<label>`.
/// Feeds the watchdog policy (crash-loop detection) and the Diagnostics UI.
public struct AgentJobInfo: Sendable, Equatable {
  public let state: String?
  public let runs: Int?
  public let lastExitCode: Int?

  public init(state: String?, runs: Int?, lastExitCode: Int?) {
    self.state = state
    self.runs = runs
    self.lastExitCode = lastExitCode
  }

  /// launchd keeps rescheduling spawns that fail before the minimum runtime
  /// (e.g. EX_CONFIG when the BTM parent record points at a dead bundle
  /// path). `runs` is cumulative since boot, so the loop is detected by the
  /// exit-code + state pair, not by an absolute runs threshold.
  public var isCrashLooping: Bool {
    guard let code = lastExitCode, code != 0 else { return false }
    return state == "spawn scheduled"
  }
}

public enum LaunchdJobInfoParser {
  /// Parses `launchctl print` output. Returns nil when the output doesn't
  /// describe a job (label not found, empty, garbage).
  public static func parse(_ output: String) -> AgentJobInfo? {
    var state: String?
    var runs: Int?
    var lastExitCode: Int?
    var matchedAnyKey = false

    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let value = keyValue(line, key: "state") {
        state = value
        matchedAnyKey = true
      } else if let value = keyValue(line, key: "runs") {
        runs = Int(value)
        matchedAnyKey = true
      } else if let value = keyValue(line, key: "last exit code") {
        // "78: EX_CONFIG" / "0" / "(never exited)" — leading integer or nil.
        let leading = value.prefix(while: { $0.isNumber || $0 == "-" })
        lastExitCode = Int(leading)
        matchedAnyKey = true
      }
    }
    return matchedAnyKey ? AgentJobInfo(state: state, runs: runs, lastExitCode: lastExitCode) : nil
  }

  private static func keyValue(_ line: String, key: String) -> String? {
    guard line.hasPrefix(key + " = ") else { return nil }
    return String(line.dropFirst(key.count + 3))
  }
}
