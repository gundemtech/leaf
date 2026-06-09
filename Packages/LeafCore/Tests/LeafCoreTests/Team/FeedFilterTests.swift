//
//  FeedFilterTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 B.6 — FeedFilter enum: selection logic + label uniqueness + Hashable.
//

import XCTest
@testable import LeafCore

final class FeedFilterTests: XCTestCase {

    // MARK: - displayLabel

    func testDirectMessagesLabelIsMessages() {
        // Team UI polish — chip row must not wrap; "Direct Messages" was the
        // longest label and "Direct" adds nothing inside the Team context.
        XCTAssertEqual(FeedFilter.directMessages.displayLabel, "Messages")
    }

    // MARK: - isExclusive

    func testAllIsExclusive() {
        XCTAssertTrue(FeedFilter.all.isExclusive)
    }

    func testNonAllCasesAreNotExclusive() {
        let nonExclusive: [FeedFilter] = [
            .directMessages,
            .openTasks,
            .decisions,
            .blockers,
            .shareSource(.gitCommits),
            .shareSource(.linearIssues),
            .shareSource(.slackMentions),
            .shareSource(.githubPRs),
            .shareSource(.detectedDecisions),
            .shareSource(.detectedBlockers),
            .shareSource(.detectedOpenQuestions),
            .shareSource(.detectedWhereStopped),
            .shareSource(.rawGitHubActivity),
        ]
        for filter in nonExclusive {
            XCTAssertFalse(filter.isExclusive, "\(filter) should not be exclusive")
        }
    }

    // MARK: - displayLabel uniqueness

    func testShareSourceMappingHasUniqueLabels() {
        // Build all shareSource filters + the fixed cases
        var allFilters: [FeedFilter] = [
            .all, .directMessages, .openTasks, .decisions, .blockers
        ]
        for source in ShareSource.allCases {
            allFilters.append(.shareSource(source))
        }

        let labels = allFilters.map(\.displayLabel)
        let unique = Set(labels)
        XCTAssertEqual(labels.count, unique.count,
                       "All FeedFilter display labels must be unique")
    }

    // MARK: - Hashable / Set membership

    func testHashableUsableAsDictionaryKey() {
        var counts: [FeedFilter: Int] = [:]
        counts[.all] = 1
        counts[.directMessages] = 2
        counts[.shareSource(.gitCommits)] = 3
        counts[.shareSource(.linearIssues)] = 4

        XCTAssertEqual(counts[.all], 1)
        XCTAssertEqual(counts[.directMessages], 2)
        XCTAssertEqual(counts[.shareSource(.gitCommits)], 3)
        XCTAssertEqual(counts[.shareSource(.linearIssues)], 4)
        XCTAssertNil(counts[.blockers])
    }

    func testSetContainment() {
        var selected: Set<FeedFilter> = [.all]
        XCTAssertTrue(selected.contains(.all))
        XCTAssertFalse(selected.contains(.directMessages))

        selected.remove(.all)
        selected.insert(.directMessages)
        selected.insert(.decisions)

        XCTAssertFalse(selected.contains(.all))
        XCTAssertTrue(selected.contains(.directMessages))
        XCTAssertTrue(selected.contains(.decisions))
    }

    // MARK: - displayLabel non-empty

    func testAllFiltersHaveNonEmptyDisplayLabel() {
        let filters: [FeedFilter] = [
            .all, .directMessages, .openTasks, .decisions, .blockers
        ] + ShareSource.allCases.map { .shareSource($0) }

        for filter in filters {
            XCTAssertFalse(filter.displayLabel.isEmpty,
                           "\(filter) has empty displayLabel")
        }
    }

    // MARK: - shareSource wrapping

    func testShareSourceDisplayLabelMatchesSourceDisplayName() {
        for source in ShareSource.allCases {
            let filter = FeedFilter.shareSource(source)
            XCTAssertEqual(filter.displayLabel, source.displayName,
                           "shareSource(\(source)) label must equal source.displayName")
        }
    }
}
