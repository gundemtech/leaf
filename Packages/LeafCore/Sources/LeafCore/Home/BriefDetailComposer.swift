//
//  BriefDetailComposer.swift
//  Use-case rebuild Track B3 — "read full brief →": sectioned detail behind
//  the Monday-brief counters. Pure composition; the sheet renders sections.
//

import Foundation

public struct BriefDetail: Equatable, Sendable {
  public struct Section: Equatable, Sendable, Identifiable {
    public let title: String
    public let items: [BriefItem]

    public var id: String { title }

    public init(title: String, items: [BriefItem]) {
      self.title = title
      self.items = items
    }
  }

  public let sections: [Section]

  public init(sections: [Section]) {
    self.sections = sections
  }
}

public enum BriefDetailComposer {

  /// Empty sections are omitted; section order mirrors the counter order of
  /// the brief card.
  public static func compose(
    snapshot: BriefSnapshot,
    decisions: [DecisionView],
    blockers: [BlockerView]
  ) -> BriefDetail {
    var sections: [BriefDetail.Section] = []

    if !snapshot.prItems.isEmpty {
      sections.append(.init(title: "PRS MERGED", items: snapshot.prItems))
    }
    if !snapshot.ticketItems.isEmpty {
      sections.append(.init(title: "TICKETS DONE", items: snapshot.ticketItems))
    }
    let decisionItems = decisions
      .sorted { $0.detectedAtMs > $1.detectedAtMs }
      .prefix(BriefComposer.itemsCap)
      .map { d in
        BriefItem(ref: "decision:\(d.id)", title: d.reasoningExcerpt, sourceURL: nil)
      }
    if !decisionItems.isEmpty {
      sections.append(.init(title: "DECISIONS SURFACED", items: Array(decisionItems)))
    }
    let blockerItems = blockers
      .filter { $0.resolvedAtMs != nil }
      .sorted { ($0.resolvedAtMs ?? 0) > ($1.resolvedAtMs ?? 0) }
      .prefix(BriefComposer.itemsCap)
      .map { b in
        BriefItem(ref: b.targetRef, title: b.blockerExcerpt, sourceURL: nil)
      }
    if !blockerItems.isEmpty {
      sections.append(.init(title: "BLOCKERS RESOLVED", items: Array(blockerItems)))
    }
    return BriefDetail(sections: sections)
  }
}
