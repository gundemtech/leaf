import XCTest

@testable import LeafCore

final class SupabaseEndpointTests: XCTestCase {
  private let baseURL = URL(string: "https://jwxnhwyqjzjmjnmwpwyq.supabase.co")!

  func testSignupAnonymousURL() {
    let url = SupabaseEndpoint.signupAnonymous(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/signup")
  }

  func testTokenRefreshURL() {
    let url = SupabaseEndpoint.tokenRefresh(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/token?grant_type=refresh_token")
  }

  func testRegisterPubkeyURL() {
    let url = SupabaseEndpoint.registerPubkey(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/register_pubkey")
  }

  func testInviteResolveURL() {
    let url = SupabaseEndpoint.inviteResolve(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/invite_resolve")
  }

  func testPostInviteURL() {
    let url = SupabaseEndpoint.postInvite(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/rest/v1/invites")
  }

  // M-II (B2-B8) — the 6 PostgREST INSERT endpoints were replaced by Edge
  // Function wraps. insertWorkspaceMember moved from /rest/v1/workspace_members
  // to /functions/v1/insert_workspace_member (now named insertWorkspaceMemberEdge).
  func testInsertWorkspaceEdgeURL() {
    let url = SupabaseEndpoint.insertWorkspaceEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/insert_workspace")
  }

  func testInsertInviteTokenEdgeURL() {
    let url = SupabaseEndpoint.insertInviteTokenEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/insert_invite_token")
  }

  func testInsertWorkspaceMemberEdgeURL() {
    let url = SupabaseEndpoint.insertWorkspaceMemberEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/insert_workspace_member")
  }

  func testSendTeamEventEdgeURL() {
    let url = SupabaseEndpoint.sendTeamEventEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/send_team_event")
  }

  func testSendDirectMessageEdgeURL() {
    let url = SupabaseEndpoint.sendDirectMessageEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/send_direct_message")
  }

  func testSubmitWaitlistEdgeURL() {
    let url = SupabaseEndpoint.submitWaitlistEdge(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/functions/v1/submit_waitlist")
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
