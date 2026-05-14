//
//  SupabaseEndpoint.swift
//  LeafCore
//
//  Track 5 / S3 — URL composition + standard header sets for Supabase REST + Edge Function endpoints.
//  Pure value-style — no I/O, easy to unit test.
//

import Foundation

public enum SupabaseEndpoint {

    // MARK: - Auth endpoints

    public static func signupAnonymous(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("auth/v1/signup")
    }

    public static func tokenRefresh(baseURL: URL) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        return components.url!
    }

    // MARK: - Edge Functions

    public static func registerPubkey(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/register_pubkey")
    }

    public static func inviteResolve(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/invite_resolve")
    }

    // MARK: - PostgREST tables

    public static func postInvite(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/invites")
    }

    public static func insertWorkspaceMember(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/workspace_members")
    }

    // MARK: - Header builders

    public static func anonHeaders(anonKey: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Content-Type": "application/json",
        ]
    }

    public static func authenticatedHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
        ]
    }

    public static func postgrestInsertHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        ]
    }
}
