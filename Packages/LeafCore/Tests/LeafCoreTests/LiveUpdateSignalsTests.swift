//
//  LiveUpdateSignalsTests.swift
//  LeafCoreTests
//
//  Live-tabs — monotonic invalidation counters for SwiftUI .onChange fan-out.
//

import Testing
@testable import LeafCore

@MainActor
struct LiveUpdateSignalsTests {

  @Test func countersStartAtZero() {
    let s = LiveUpdateSignals()
    #expect(s.localDataVersion == 0)
    #expect(s.teamFeedVersion == 0)
  }

  @Test func bumpsAreIndependentAndMonotonic() {
    let s = LiveUpdateSignals()
    s.bumpLocalData()
    s.bumpLocalData()
    s.bumpTeamFeed()
    #expect(s.localDataVersion == 2)
    #expect(s.teamFeedVersion == 1)
  }
}
