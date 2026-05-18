//
//  SupabaseClient+Workspaces.swift
//  LeafCore
//
//  Track 5 / S7 E.3 + E.4 — Workspace PATCH mutations via Supabase PostgREST.
//
//  Both methods PATCH /rest/v1/workspaces?id=eq.<id>. RLS policy (M025
//  `workspaces_creator_update`) gates writes to the workspace creator only —
//  non-admin callers receive 403 Forbidden mapped to `SupabaseError.forbidden`.
//
//  Validation duplicates `WorkspaceService.updateName` for defence-in-depth
//  so that the network call is never fired with an invalid payload even if the
//  caller skips the local-service layer.
//

import Foundation

extension SupabaseClient {

    // MARK: - E.3: patchWorkspaceName

    /// PATCH workspace display name on Supabase.
    ///
    /// - Parameters:
    ///   - id: UUID of the workspace row to update.
    ///   - name: New display name. Trimmed before sending; must be non-empty
    ///     and ≤ 80 characters after trim, otherwise throws `LeafError.invalidPayload`
    ///     without firing a network call.
    /// - Throws: `LeafError.invalidPayload` on empty / too-long name,
    ///   `SupabaseError.forbidden` on RLS denial, `SupabaseError.transport` on
    ///   network failure, or any other `SupabaseError` for non-2xx responses.
    ///
    /// Caller should call `WorkspaceService.updateName` first to persist the
    /// change locally, then call this to sync with Supabase.
    public func patchWorkspaceName(id: String, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw LeafError.invalidPayload
        }
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.workspaceByID(id, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        for (k, v) in SupabaseEndpoint.postgrestPatchHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": trimmed])

        let (data, response) = try await workspacesTransport(request, label: "patchWorkspaceName")
        // PostgREST PATCH returns 204 No Content on success when Prefer: return=minimal.
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw SupabaseError.fromStatus(response.statusCode, body: data)
        }
    }

    // MARK: - E.4: softDeleteWorkspace

    /// PATCH `deleted_at_ms` on the Supabase workspace row (soft-delete).
    ///
    /// - Parameter id: UUID of the workspace row to soft-delete.
    /// - Throws: `SupabaseError.forbidden` on RLS denial, `SupabaseError.transport`
    ///   on network failure, or any other `SupabaseError` for non-2xx responses.
    ///
    /// Call `WorkspaceService.softDelete(workspaceID:at:)` after this succeeds
    /// to wipe the local SQLCipher rows and keystore directory.
    public func softDeleteWorkspace(id: String) async throws {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.workspaceByID(id, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        for (k, v) in SupabaseEndpoint.postgrestPatchHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deleted_at_ms": nowMs])

        let (data, response) = try await workspacesTransport(request, label: "softDeleteWorkspace")
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw SupabaseError.fromStatus(response.statusCode, body: data)
        }
    }

    // MARK: - Private transport helper (local to this extension)

    /// Mirrors the pattern from `SupabaseClient+DirectMessages.swift` and
    /// `SupabaseClient+TeamEvents.swift` — each extension owns its private transport
    /// wrapper to avoid cross-file visibility issues with the actor's internals.
    private func workspacesTransport(
        _ request: URLRequest,
        label: String
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "\(label): \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "\(label): non-http")
        }
        return (data, http)
    }
}
