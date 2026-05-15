//
//  LinearScopesServiceTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T5 — verifies LinearScopesService actor symmetric with
//  SlackScopesService. requiredCore = ["read"]; requiredOptional = ["issues:create"]
//  per A3 brainstorm (narrower than `write`).
//

import Foundation
import Testing
@testable import LeafCore

@Suite("LinearScopesService")
struct LinearScopesServiceTests {
    @Test("requiredCore is exactly [read]")
    func requiredCoreShape() {
        #expect(LinearScopesService.requiredCore == ["read"])
    }

    @Test("requiredOptional is exactly [issues:create]")
    func requiredOptionalShape() {
        #expect(LinearScopesService.requiredOptional == ["issues:create"])
    }

    @Test("requested returns sorted union")
    func requestedSorted() {
        let req = LinearScopesService.requested()
        #expect(req == ["issues:create", "read"])
    }

    @Test("override with read only → missing empty, missingOptional has issues:create")
    func readOnlyOverride() async {
        let svc = LinearScopesService(grantedOverride: ["read"])
        #expect(await svc.currentGranted() == ["read"])
        #expect(await svc.missing() == [])
        #expect(await svc.missingOptional() == ["issues:create"])
    }

    @Test("override with full set → all satisfied")
    func fullOverride() async {
        let svc = LinearScopesService(grantedOverride: ["read", "issues:create"])
        #expect(await svc.missing() == [])
        #expect(await svc.missingOptional() == [])
        #expect(await svc.has("issues:create") == true)
    }

    @Test("override with empty set → missing has read")
    func emptyOverride() async {
        let svc = LinearScopesService(grantedOverride: [])
        #expect(await svc.missing() == ["read"])
    }

    @Test("has() returns false for ungranted scope")
    func hasUngranted() async {
        let svc = LinearScopesService(grantedOverride: ["read"])
        #expect(await svc.has("issues:create") == false)
    }

    @Test("parseScopeString — comma-separated")
    func parseComma() {
        #expect(LinearScopesService.parseScopeString("read,issues:create") == ["read", "issues:create"])
    }

    @Test("parseScopeString — whitespace-separated")
    func parseWhitespace() {
        #expect(LinearScopesService.parseScopeString("read issues:create") == ["read", "issues:create"])
    }

    @Test("parseScopeString — empty string returns empty set")
    func parseEmpty() {
        #expect(LinearScopesService.parseScopeString("") == [])
    }

    @Test("parseScopeString — extra whitespace tolerated")
    func parseExtraSpaces() {
        #expect(LinearScopesService.parseScopeString("read, issues:create ") == ["read", "issues:create"])
    }

    @Test("conforms to LinearScopesChecking protocol")
    func protocolConformance() async {
        let svc: any LinearScopesChecking = LinearScopesService(grantedOverride: ["read"])
        #expect(await svc.has("read") == true)
        #expect(await svc.has("issues:create") == false)
    }
}
