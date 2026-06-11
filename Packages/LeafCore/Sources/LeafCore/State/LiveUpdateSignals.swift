//
//  LiveUpdateSignals.swift
//  LeafCore
//
//  Live-tabs — two monotonic invalidation counters bridging change sources to
//  SwiftUI views via .onChange. Two counters in ONE type because SwiftUI
//  .environment(_:) is type-keyed (two instances of one type can't coexist);
//  Observation tracks per-property, so Home churn never re-renders TeamView.
//
//    localDataVersion — agent-written insights data changed on disk
//                       (bumped by DatabaseChangeObserver via composition root)
//    teamFeedVersion  — DM / team-event mirror tables changed in-process
//                       (bumped by reader onMirrorChanged closures)
//

import Foundation
import Observation

@MainActor
@Observable
public final class LiveUpdateSignals {

  public private(set) var localDataVersion: Int = 0
  public private(set) var teamFeedVersion: Int = 0

  public init() {}

  public func bumpLocalData() {
    localDataVersion += 1
  }

  public func bumpTeamFeed() {
    teamFeedVersion += 1
  }
}
