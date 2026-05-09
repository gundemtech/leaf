import Foundation

/// Typed counterpart to `Schema.BodyKinds` raw strings. Detectors switch over
/// this enum; storage layer keeps the string constants as DB-level identifiers.
public enum BodyKind: String, Sendable, Equatable, CaseIterable {
    case commitMsg = "commit_msg"
    case linearDesc = "linear_desc"
    case linearComment = "linear_comment"
    case slackMsg = "slack_msg"
    case slackThreadParent = "slack_thread_parent"
    case slackThreadReply = "slack_thread_reply"
    case ghPR = "gh_pr"
    case ghIssueComment = "gh_issue_comment"
    case ghPRReviewComment = "gh_pr_review_comment"
}

public struct DecisionHit: Sendable, Equatable {
    public let topicKeywords: [String]
    public let reasoningExcerpt: String
    public let confidence: Double

    public init(topicKeywords: [String], reasoningExcerpt: String, confidence: Double) {
        self.topicKeywords = topicKeywords
        self.reasoningExcerpt = reasoningExcerpt
        self.confidence = confidence
    }
}

public struct OpenQuestionHit: Sendable, Equatable {
    public let questionExcerpt: String
    public let alternatives: [String]?

    public init(questionExcerpt: String, alternatives: [String]?) {
        self.questionExcerpt = questionExcerpt
        self.alternatives = alternatives
    }
}

public struct BlockerPatternHit: Sendable, Equatable {
    public let blockerExcerpt: String

    public init(blockerExcerpt: String) {
        self.blockerExcerpt = blockerExcerpt
    }
}

public struct LinearStuckHit: Sendable, Equatable {
    public let issueRef: String
    public let lastStatusTransitionAtMs: Int64

    public init(issueRef: String, lastStatusTransitionAtMs: Int64) {
        self.issueRef = issueRef
        self.lastStatusTransitionAtMs = lastStatusTransitionAtMs
    }
}

public struct WipSignals: Sendable, Equatable, Codable {
    public let commitWip: Bool
    public let ciFailing: Bool
    public let midEdit: Bool

    public init(commitWip: Bool, ciFailing: Bool, midEdit: Bool) {
        self.commitWip = commitWip
        self.ciFailing = ciFailing
        self.midEdit = midEdit
    }
}

public struct WhereStoppedOutput: Sendable, Equatable, Codable {
    public let excerpt: String
    public let wipSignals: WipSignals
    public let anchorEventID: Int64?

    public init(excerpt: String, wipSignals: WipSignals, anchorEventID: Int64?) {
        self.excerpt = excerpt
        self.wipSignals = wipSignals
        self.anchorEventID = anchorEventID
    }
}

public struct SlackIdentifier: Sendable, Equatable {
    public let userID: String
    public let displayName: String?
    public let realName: String?

    public init(userID: String, displayName: String?, realName: String?) {
        self.userID = userID
        self.displayName = displayName
        self.realName = realName
    }
}

public struct AbsenceFlag: Sendable, Equatable, Codable {
    public let prRef: String
    public let reviewerLogin: String
    public let designChoiceExcerpt: String
    public let lastThreadActivityMs: Int64

    public init(
        prRef: String,
        reviewerLogin: String,
        designChoiceExcerpt: String,
        lastThreadActivityMs: Int64
    ) {
        self.prRef = prRef
        self.reviewerLogin = reviewerLogin
        self.designChoiceExcerpt = designChoiceExcerpt
        self.lastThreadActivityMs = lastThreadActivityMs
    }
}
