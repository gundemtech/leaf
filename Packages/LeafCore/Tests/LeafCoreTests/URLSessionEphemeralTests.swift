// Phase 5 defence-in-depth — URLSession.leafEphemeral() factory invariants.
// OAuth token-exchange / refresh + relay traffic must not persist responses to a
// disk cache. The app-target OAuth services + LeafCore refreshers / RelayClient /
// Google clients all default to this factory, so asserting its configuration here
// covers them transitively (no SwiftPM app-target test bundle exists).

import XCTest

@testable import LeafCore

final class URLSessionEphemeralTests: XCTestCase {
    func testLeafEphemeralHasNilURLCache() {
        // The concrete proof a token response cannot land in a disk cache.
        XCTAssertNil(URLSession.leafEphemeral().configuration.urlCache)
    }

    func testLeafEphemeralHasNilCookieStorage() {
        XCTAssertNil(URLSession.leafEphemeral().configuration.httpCookieStorage)
    }

    func testLeafEphemeralHasNilCredentialStorage() {
        XCTAssertNil(URLSession.leafEphemeral().configuration.urlCredentialStorage)
    }

    func testLeafEphemeralBypassesLocalCache() {
        XCTAssertEqual(
            URLSession.leafEphemeral().configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData)
    }
}
