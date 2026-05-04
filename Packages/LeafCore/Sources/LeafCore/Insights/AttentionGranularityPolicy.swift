//
//  AttentionGranularityPolicy.swift
//  LeafCore
//
//  Phase 4.10.B — forward-compat shim под будущий `share_apps` DB lookup.
//  Hardcoded mapping `bundleID → maxGranularity (L1..L5)` определяет, нужно ли
//  collector'у писать window_title / browser_url в attention payload.
//
//  Когда Share Controls Phase 2 landed (table `share_apps` + UI) — переключаем
//  `DefaultAttentionGranularityPolicy` на DB lookup без изменения call-sites.
//

import Foundation

/// Granularity ceiling per ADR-013. См. `architecture.md` раздел "Granularity
/// levels и маппинг на источники". L6 (content) запрещён всегда.
public enum AttentionGranularityLevel: Int, Sendable {
    case l1 = 1   // app only (bundle ID)
    case l2 = 2   // app + intensity (idle ratio)
    case l3 = 3   // app + window title (или browser URL для browse-категории)
    case l4 = 4   // app + folder/module
    case l5 = 5   // app + file name (opt-in per folder)
}

public protocol AttentionGranularityPolicy: Sendable {
    func maxGranularity(for bundleID: String) -> AttentionGranularityLevel
}

/// Default policy — hardcoded category-based defaults. Conservative L1 для
/// неизвестных приложений; L3 для known dev / browse / communication / design.
public struct DefaultAttentionGranularityPolicy: AttentionGranularityPolicy {
    public init() {}

    public func maxGranularity(for bundleID: String) -> AttentionGranularityLevel {
        switch AppCategoryClassifier.category(for: bundleID) {
        case .dev, .browse, .communication, .design:
            return .l3
        case .other:
            return .l1
        }
    }
}
