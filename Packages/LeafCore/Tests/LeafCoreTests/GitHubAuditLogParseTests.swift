//
//  GitHubAuditLogParseTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 10. Payload-construction tests for
//  `GitHubColdCollector.makeAuditActionObservedEvent(...)`.
//
//  Verifies canonical event_kind ("gh_audit_action_observed"), `action`,
//  `actor_login`, `observed_at_ms` keys present + signal type. ADR-010 §6:
//  no `description` / `data.*` / no body content from audit log.
//

import XCTest
@testable import LeafCore

final class GitHubAuditLogParseTests: XCTestCase {
    private func entry(action: String, actor: String = "octocat", at: Int64 = 1_000) -> GitHubAuditLogEntry {
        GitHubAuditLogEntry(action: action, actorLogin: actor, createdAtMs: at)
    }

    func testRepoCreateAction() {
        let e = entry(action: "repo.create", actor: "alice", at: 1_700_000_000_000)
        let event = GitHubColdCollector.makeAuditActionObservedEvent(e, observedAtMs: 1_700_000_000_500)
        XCTAssertEqual(event.payload["event_kind"], "gh_audit_action_observed")
        XCTAssertEqual(event.payload["source"], "github")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditAction], "repo.create")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditActorLogin], "alice")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.observedAtMs], "1700000000500")
        XCTAssertEqual(event.signalType, .action)
    }

    func testTeamAddMember() {
        let e = entry(action: "team.add_member", actor: "bob")
        let event = GitHubColdCollector.makeAuditActionObservedEvent(e, observedAtMs: 2_000)
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditAction], "team.add_member")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditActorLogin], "bob")
    }

    func testOrgInviteMember() {
        let e = entry(action: "org.invite_member")
        let event = GitHubColdCollector.makeAuditActionObservedEvent(e, observedAtMs: 3_000)
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditAction], "org.invite_member")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditActorLogin], "octocat")
    }

    func testRepoTransferAction() {
        let e = entry(action: "repo.transfer", actor: "carol")
        let event = GitHubColdCollector.makeAuditActionObservedEvent(e, observedAtMs: 4_000)
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditAction], "repo.transfer")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditActorLogin], "carol")
        // Privacy guardrail: no `description`, no `data.*` keys.
        XCTAssertNil(event.payload["description"])
        XCTAssertNil(event.payload["data"])
    }

    func testUnknownActionStillEmits() {
        let e = entry(action: "weird.unknown_thing", actor: "dave")
        let event = GitHubColdCollector.makeAuditActionObservedEvent(e, observedAtMs: 5_000)
        // No allow-listing of action strings — collector emits whatever GitHub
        // hands back (action discriminator stays a free-form string).
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.auditAction], "weird.unknown_thing")
        XCTAssertEqual(event.payload["event_kind"], "gh_audit_action_observed")
    }
}
