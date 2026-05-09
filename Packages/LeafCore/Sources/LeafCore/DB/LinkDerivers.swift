import Foundation

/// Phase Track-1 D2 — confidence values per link_kind, in [0, 1].
/// Public substrate ships safe defaults; LeafCorePrivate `prodLinkDerivers()`
/// supplies the tuned moat values.
public struct LinkConfidenceValues: Sendable {
    public let linearIDInText: Double
    public let branchNameLinearRef: Double
    public let prURLInSlack: Double
    public let prNumberHashRef: Double
    public let reviewerAssigned: Double

    public init(
        linearIDInText: Double,
        branchNameLinearRef: Double,
        prURLInSlack: Double,
        prNumberHashRef: Double,
        reviewerAssigned: Double
    ) {
        self.linearIDInText = linearIDInText
        self.branchNameLinearRef = branchNameLinearRef
        self.prURLInSlack = prURLInSlack
        self.prNumberHashRef = prNumberHashRef
        self.reviewerAssigned = reviewerAssigned
    }

    /// Conservative non-zero defaults shipped in the public substrate. Tuned
    /// values live in LeafCorePrivate `LinkConfidence`.
    public static let publicDefault = LinkConfidenceValues(
        linearIDInText: 0.5,
        branchNameLinearRef: 0.5,
        prURLInSlack: 0.5,
        prNumberHashRef: 0.5,
        reviewerAssigned: 1.0
    )
}

/// Phase Track-1 D2 — injection struct supplying the moat extractors + confidence
/// values to `EventLinksStore.deriveLinks`. LeafCore cannot import LeafCorePrivate
/// (`Package.swift:32-39` — LeafCorePrivate depends on LeafCore, not the reverse),
/// so the moat code is reached through closures wired in by callers that *can*
/// import both (LeafCorePrivate — the production wiring; tests in LeafCorePrivateTests).
///
/// `publicSubstrate` defaults to no-op closures for branch / PR-URL / PR-hash
/// extraction (returns nil / []). LinearID extraction is in LeafCore proper, so
/// `EventLinksStore` always wires that path directly without going through this
/// struct. Reviewer fan-out is structured payload — also direct, no closure.
public struct LinkDerivers: Sendable {
    public let extractBranchLinearID: @Sendable (_ branch: String, _ knownPrefixes: Set<String>) -> String?
    public let extractPRURLs: @Sendable (_ text: String) -> [String]
    public let extractPRHashRefs: @Sendable (_ text: String) -> [String]
    public let confidence: LinkConfidenceValues

    public init(
        extractBranchLinearID: @escaping @Sendable (_ branch: String, _ knownPrefixes: Set<String>) -> String?,
        extractPRURLs: @escaping @Sendable (_ text: String) -> [String],
        extractPRHashRefs: @escaping @Sendable (_ text: String) -> [String],
        confidence: LinkConfidenceValues
    ) {
        self.extractBranchLinearID = extractBranchLinearID
        self.extractPRURLs = extractPRURLs
        self.extractPRHashRefs = extractPRHashRefs
        self.confidence = confidence
    }

    /// Public-substrate default — moat extractors return nil/[]. Used by callers
    /// without LeafCorePrivate wiring (CI, public-API integration tests).
    public static let publicSubstrate = LinkDerivers(
        extractBranchLinearID: { _, _ in nil },
        extractPRURLs: { _ in [] },
        extractPRHashRefs: { _ in [] },
        confidence: .publicDefault
    )
}
