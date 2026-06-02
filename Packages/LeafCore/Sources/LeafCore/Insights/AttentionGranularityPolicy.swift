//
//  AttentionGranularityPolicy.swift
//  LeafCore
//
//  Phase 4.10.B — forward-compat shim for the future `share_apps` DB lookup.
//  The mapping `bundleID → maxGranularity (L1..L5)` decides whether the
//  collector should write window_title / browser_url into the attention payload.
//
//  Once Share Controls Phase 2 lands (the `share_apps` table + UI), we switch
//  `DefaultAttentionGranularityPolicy` to a DB lookup without changing call-sites.
//

import Foundation

/// Granularity ceiling per ADR-013. See the `architecture.md` "Granularity
/// levels" section (signal-source-to-level mapping). L6 (content) is always forbidden.
public enum AttentionGranularityLevel: Int, Sendable {
    case l1 = 1   // app only (bundle ID)
    case l2 = 2   // app + intensity (idle ratio)
    case l3 = 3   // app + window title (or browser URL for the browse category)
    case l4 = 4   // app + folder/module
    case l5 = 5   // app + file name (opt-in per folder)
}

public protocol AttentionGranularityPolicy: Sendable {
    func maxGranularity(for bundleID: String) -> AttentionGranularityLevel
}

/// Category-driven policy. Injects the classifier via init — the composition root
/// decides whether to use the moat `ProdAppCategoryClassifier` (full preset)
/// or the public `EmptyAppCategoryClassifier` (everything → L1).
public struct DefaultAttentionGranularityPolicy: AttentionGranularityPolicy {
    private let classifier: any AppCategoryClassifier

    public init(classifier: any AppCategoryClassifier = EmptyAppCategoryClassifier()) {
        self.classifier = classifier
    }

    public func maxGranularity(for bundleID: String) -> AttentionGranularityLevel {
        switch classifier.category(for: bundleID) {
        case .dev, .browse, .communication, .design:
            return .l3
        case .other:
            return .l1
        }
    }
}
