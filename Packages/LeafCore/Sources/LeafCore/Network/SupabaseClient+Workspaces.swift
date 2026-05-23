//
//  SupabaseClient+Workspaces.swift
//  LeafCore
//
//  Track 5 / S7 E.3 + E.4 — Workspace PATCH mutations via Supabase PostgREST.
//
//  Both PATCH methods hit /rest/v1/workspaces?id=eq.<id>. RLS policy (M025
//  `workspaces_creator_update`) gates writes to the workspace creator only —
//  non-admin callers receive 403 Forbidden mapped to `SupabaseError.forbidden`.
//
//  M027 follow-up — `insertWorkspace` POSTs the workspace row to the server
//  on local-creation time so the server-side `is_workspace_admin` RLS helper
//  (which queries `workspaces.created_by_pubkey`) returns true for every
//  subsequent admin operation (`invite_tokens` write, `invites` write, etc.).
//
//  M-II — `insertWorkspace` now calls the `insert_workspace` Edge Function
//  (functions/v1/insert_workspace) instead of the PostgREST /rest/v1/workspaces
//  endpoint. The Edge Function adds server-side idempotency via Idempotency-Key
//  dedup so retries after transient failures are safe.
//
//  `insertWorkspaceMember` is co-located here (moved from SupabaseClient.swift
//  B5) since it mirrors the workspace-scope INSERT pattern and callers are the
//  same service layer (InviteAcceptService).
//
//  Validation duplicates `WorkspaceService.updateName` for defence-in-depth
//  so that the network call is never fired with an invalid payload even if the
//  caller skips the local-service layer.
//

import Foundation

extension SupabaseClient {

  // MARK: - M027 / M-II — insertWorkspace (admin self-insert via Edge Function)

  /// POST a freshly-created workspace row via the `insert_workspace` Edge
  /// Function. The Edge Function handles idempotency (Idempotency-Key dedup)
  /// and auth (JWT pubkey claim → created_by_pubkey). Returns Void; server
  /// authoritative `created_at` is not needed by the caller.
  ///
  /// - Parameters:
  ///   - id: UUID of the workspace row (canonical lowercase form).
  ///   - name: display name. Trimmed before sending; ≤80 chars after trim.
  ///   - createdByPubkey: admin's X25519 pubkey hex (64 lowercase hex chars).
  ///     Passed for body-hash inclusion in idempotency key; the Edge Function
  ///     also extracts the pubkey from the JWT claim for the DB INSERT.
  /// - Throws: `LeafError.invalidPayload` on empty/too-long name,
  ///   `SupabaseError.conflict` on 409 workspace_exists,
  ///   `SupabaseError.forbidden` on auth denial, transport errors otherwise.
  public func insertWorkspace(
    id: String,
    name: String,
    createdByPubkey: String
  ) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      throw LeafError.invalidPayload
    }
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.insertWorkspaceEdge(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let body: [String: Any] = [
      "workspace_id": id,
      "name": trimmed,
      "created_at_ms": createdAtMs,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await workspacesTransport(
      request, label: "insertWorkspace", retryable: true, refreshable: true,
      idempotent: true)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // Edge response: { workspace_id, name, created_at } — Void return; discard.
    _ = data
  }

  // MARK: - B5 / M-II — insertWorkspaceMember (relocated from SupabaseClient.swift)

  /// POST a new workspace-member row via the `insert_workspace_member` Edge
  /// Function. Idempotent — safe to retry on transient failure (Idempotency-Key
  /// dedup on server). 409 workspace_member_exists maps to `SupabaseError.conflict`.
  ///
  /// - Parameters:
  ///   - workspaceID: UUID of the workspace.
  ///   - pubkeyHex: 64-hex X25519 pubkey of the joining member.
  ///   - displayName: member's display name (non-empty, ≤100 chars).
  /// - Throws: `SupabaseError.conflict` on duplicate (workspace_id, pubkey),
  ///   `SupabaseError.forbidden` on auth denial, transport errors otherwise.
  public func insertWorkspaceMember(
    workspaceID: String,
    pubkeyHex: String,
    displayName: String
  ) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.insertWorkspaceMemberEdge(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let joinedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let body: [String: Any] = [
      "workspace_id": workspaceID,
      "member_pubkey": pubkeyHex,
      "display_name": displayName,
      "joined_at_ms": joinedAtMs,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await workspacesTransport(
      request, label: "insertWorkspaceMember", retryable: true, refreshable: true,
      idempotent: true)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // Edge response: { workspace_id, member_pubkey, joined_at } — Void return; discard.
    _ = data
  }

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
    for (k, v) in SupabaseEndpoint.postgrestPatchHeadersWithCount(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": trimmed])

    let (data, response) = try await workspacesTransport(
      request, label: "patchWorkspaceName", retryable: true, refreshable: true)
    // PostgREST PATCH returns 204 No Content on success when Prefer: return=minimal.
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // S7 Stage 6 fix C-I9 — detect silent-0-row RLS-deny outcomes.
    try Self.assertContentRangeNonZero(response: response)
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
    for (k, v) in SupabaseEndpoint.postgrestPatchHeadersWithCount(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    request.httpBody = try JSONSerialization.data(withJSONObject: ["deleted_at_ms": nowMs])

    let (data, response) = try await workspacesTransport(
      request, label: "softDeleteWorkspace", retryable: true, refreshable: true)
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // S7 Stage 6 fix C-I9 — detect silent-0-row RLS-deny outcomes.
    try Self.assertContentRangeNonZero(response: response)
  }

  /// PostgREST's `Prefer: count=exact` adds a `Content-Range` header in the
  /// form `0-(N-1)/N` on success, or `*/0` when zero rows matched the
  /// `?id=eq.<uuid>` filter (e.g., the RLS USING-clause filtered the row
  /// out for this caller). We throw `.noRowsAffected` in the latter case so
  /// callers can distinguish "looks like success but server didn't actually
  /// mutate anything" from genuine success.
  ///
  /// Header missing → treat as success (older PostgREST versions or
  /// non-Supabase mocks may not include the header).
  private static func assertContentRangeNonZero(response: HTTPURLResponse) throws {
    guard let range = response.value(forHTTPHeaderField: "Content-Range") else {
      return
    }
    // Shape examples: "0-0/1", "*/0", "0-9/10".
    // Affected count is the suffix after `/`.
    let parts = range.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let total = Int(parts[1]) else {
      return  // unparseable → defensive success
    }
    if total == 0 {
      throw SupabaseError.noRowsAffected
    }
  }

  // MARK: - Private transport helper (local to this extension)

  /// Mirrors the pattern from `SupabaseClient+DirectMessages.swift` and
  /// `SupabaseClient+TeamEvents.swift` — each extension owns its private transport
  /// wrapper to avoid cross-file visibility issues with the actor's internals.
  private func workspacesTransport(
    _ request: URLRequest,
    label: String,
    retryable: Bool = false,
    refreshable: Bool = false,
    idempotent: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(
      request, retryable: retryable, refreshable: refreshable, idempotent: idempotent, label: label)
  }
}
