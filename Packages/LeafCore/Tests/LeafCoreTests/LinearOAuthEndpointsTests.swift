//
//  LinearOAuthEndpointsTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T6 — regression tests pinning OAuth scope + actor + URLs.
//  Locks against accidental scope drift; existing connected users (read-only)
//  must re-authorize to grant `issues:create` for S6 cross-post.
//

import Foundation
import Testing
@testable import LeafCore

@Suite("LinearOAuthEndpoints")
struct LinearOAuthEndpointsTests {
    @Test("scope is read,issues:create — per A3 brainstorm (narrower than write)")
    func scopeIsReadAndIssuesCreate() {
        #expect(LinearOAuthEndpoints.scope == "read,issues:create")
    }

    @Test("scope parses to set containing read + issues:create")
    func scopeParses() {
        let parsed = LinearScopesService.parseScopeString(LinearOAuthEndpoints.scope)
        #expect(parsed == ["read", "issues:create"])
    }

    @Test("actor is user (created-by attribution shows sender natively)")
    func actorIsUser() {
        #expect(LinearOAuthEndpoints.actor == "user")
    }

    @Test("authorize URL is https://linear.app/oauth/authorize")
    func authorizeURL() {
        #expect(LinearOAuthEndpoints.authorize.absoluteString == "https://linear.app/oauth/authorize")
    }

    @Test("token URL is https://api.linear.app/oauth/token")
    func tokenURL() {
        #expect(LinearOAuthEndpoints.token.absoluteString == "https://api.linear.app/oauth/token")
    }

    @Test("graphql URL is https://api.linear.app/graphql")
    func graphqlURL() {
        #expect(LinearOAuthEndpoints.graphql.absoluteString == "https://api.linear.app/graphql")
    }
}
