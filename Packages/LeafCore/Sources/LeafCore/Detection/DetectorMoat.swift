import Foundation
import GRDB

/// Injection struct supplying detector implementations to the D3 pipeline.
/// LeafCore cannot import LeafCorePrivate (`Package.swift` — LeafCorePrivate
/// depends on LeafCore, not the reverse), so production regex/heuristic code
/// is reached through protocol-typed fields wired in by callers that *can*
/// import both (LeafCorePrivate factory; tests in LeafCorePrivateTests).
///
/// `publicSubstrate` wires no-op implementations: detectors return nil/[] and
/// the scheduled scanners report sentinel thresholds (`Int.max`) so they are
/// effectively disabled. The CI-visible substrate ships zero detection logic.
public struct DetectorMoat: Sendable {
    public let decision: any DecisionDetectorProtocol
    public let openQuestion: any OpenQuestionDetectorProtocol
    public let blockerPattern: any BlockerPatternDetectorProtocol
    public let linearStuck: any LinearStuckScannerProtocol
    public let whereStopped: any WhereStoppedDeriverProtocol
    public let absence: any AbsenceMatcherProtocol

    public init(
        decision: any DecisionDetectorProtocol,
        openQuestion: any OpenQuestionDetectorProtocol,
        blockerPattern: any BlockerPatternDetectorProtocol,
        linearStuck: any LinearStuckScannerProtocol,
        whereStopped: any WhereStoppedDeriverProtocol,
        absence: any AbsenceMatcherProtocol
    ) {
        self.decision = decision
        self.openQuestion = openQuestion
        self.blockerPattern = blockerPattern
        self.linearStuck = linearStuck
        self.whereStopped = whereStopped
        self.absence = absence
    }

    /// Public-substrate default — no-op detectors. Used by callers without
    /// LeafCorePrivate wiring (CI, public-API integration tests).
    public static let publicSubstrate = DetectorMoat(
        decision: NoOpDecisionDetector(),
        openQuestion: NoOpOpenQuestionDetector(),
        blockerPattern: NoOpBlockerPatternDetector(),
        linearStuck: NoOpLinearStuckScanner(),
        whereStopped: NoOpWhereStoppedDeriver(),
        absence: ExactMatchAbsence()
    )
}

public struct NoOpDecisionDetector: DecisionDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? { nil }
}

public struct NoOpOpenQuestionDetector: OpenQuestionDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind) -> OpenQuestionHit? { nil }
}

public struct NoOpBlockerPatternDetector: BlockerPatternDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind) -> BlockerPatternHit? { nil }
}

public struct NoOpLinearStuckScanner: LinearStuckScannerProtocol {
    public init() {}
    public var stuckDays: Int { Int.max }
    public func currentlyStuck(in db: GRDB.Database, nowMs: Int64) throws -> [LinearStuckHit] { [] }
}

public struct NoOpWhereStoppedDeriver: WhereStoppedDeriverProtocol {
    public init() {}
    public var idleSeconds: Int { Int.max }
    public func derive(
        in db: GRDB.Database,
        sinceMs: Int64,
        untilMs: Int64
    ) throws -> WhereStoppedOutput? { nil }
}

/// Conservative public-substrate matcher — ships zero heuristics. A Slack
/// identifier matches a GitHub login only when `userID` is byte-equal to it.
/// Display-name / real-name fuzzy matching lives in LeafCorePrivate.
public struct ExactMatchAbsence: AbsenceMatcherProtocol {
    public init() {}
    public func match(
        githubLogin: String,
        slackIdentifiers: [SlackIdentifier]
    ) -> SlackIdentifier? {
        slackIdentifiers.first(where: { $0.userID == githubLogin })
    }
}
