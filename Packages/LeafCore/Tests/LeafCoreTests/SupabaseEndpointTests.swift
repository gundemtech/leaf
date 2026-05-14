import XCTest
@testable import LeafCore

final class SupabaseEndpointTests: XCTestCase {
    private let baseURL = URL(string: "https://jwxnhwyqjzjmjnmwpwyq.supabase.co")!

    func testSignupAnonymousURL() {
        let url = SupabaseEndpoint.signupAnonymous(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/signup")
    }

    func testTokenRefreshURL() {
        let url = SupabaseEndpoint.tokenRefresh(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/token?grant_type=refresh_token")
    }

    func testRegisterPubkeyURL() {
        let url = SupabaseEndpoint.registerPubkey(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/register_pubkey")
    }

    func testInviteResolveURL() {
        let url = SupabaseEndpoint.inviteResolve(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/invite_resolve")
    }

    func testPostInviteURL() {
        let url = SupabaseEndpoint.postInvite(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/rest/v1/invites")
    }

    func testInsertWorkspaceMemberURL() {
        let url = SupabaseEndpoint.insertWorkspaceMember(baseURL: baseURL)
        XCTAssertEqual(url.absoluteString,
                       "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/rest/v1/workspace_members")
    }

    func testAnonHeaders() {
        let headers = SupabaseEndpoint.anonHeaders(anonKey: "test-anon-key")
        XCTAssertEqual(headers["apikey"], "test-anon-key")
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertNil(headers["Authorization"])
    }

    func testAuthenticatedHeaders() {
        let headers = SupabaseEndpoint.authenticatedHeaders(anonKey: "anon", accessToken: "abc.def.ghi")
        XCTAssertEqual(headers["apikey"], "anon")
        XCTAssertEqual(headers["Authorization"], "Bearer abc.def.ghi")
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func testPostgRESTInsertHeaders() {
        let headers = SupabaseEndpoint.postgrestInsertHeaders(anonKey: "anon", accessToken: "tok")
        XCTAssertEqual(headers["Prefer"], "return=representation")
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
    }
}
