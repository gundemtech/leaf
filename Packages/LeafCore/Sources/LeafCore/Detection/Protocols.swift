import Foundation
import GRDB

public protocol DecisionDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit?
}

public protocol OpenQuestionDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind) -> OpenQuestionHit?
}

public protocol BlockerPatternDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind) -> BlockerPatternHit?
}

public protocol LinearStuckScannerProtocol: Sendable {
    var stuckDays: Int { get }
    func currentlyStuck(in db: GRDB.Database, nowMs: Int64) throws -> [LinearStuckHit]
}

public protocol WhereStoppedDeriverProtocol: Sendable {
    var idleSeconds: Int { get }
    func derive(
        in db: GRDB.Database,
        sinceMs: Int64,
        untilMs: Int64
    ) throws -> WhereStoppedOutput?
}

public protocol AbsenceMatcherProtocol: Sendable {
    /// Returns the matched Slack identifier or nil if no confident match.
    func match(
        githubLogin: String,
        slackIdentifiers: [SlackIdentifier]
    ) -> SlackIdentifier?
}
