//
//  SupabaseClient+JoinRequests.swift
//  LeafCore
//
//  M027 invite-redesign — wrappers over join_requests Edge Functions + REST.
//
//  Invokes:
//    invokeCreateJoinRequest    POST /functions/v1/create_join_request
//    invokeCancelJoinRequest    POST /functions/v1/cancel_join_request
//    invokeApproveJoinRequest   POST /functions/v1/approve_join_request
//    invokeDeclineJoinRequest   POST /functions/v1/decline_join_request
//    invokeDeleteInviteToken    POST /functions/v1/delete_invite_token
//
//  REST GET helpers (RLS-gated):
//    listPendingJoinRequests    workspace admin sees all pending in workspace
//    fetchOwnJoinRequest        invitee sees own row (any status)
//

import Foundation

extension SupabaseClient {

    // MARK: - Edge Function invokers

    /// Invitee path — POST a fresh pending join_request via the Edge Function
    /// (which pre-flights token validity → 410 Gone if expired/deleted/exhausted).
    /// Returns the inserted row on 201; throws on 4xx/5xx.
    public func invokeCreateJoinRequest(
        workspaceID: String,
        code: String,
        displayName: String
    ) async throws -> JoinRequest {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.createJoinRequest(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "workspace_id": workspaceID,
            "code": code,
            "display_name": displayName,
        ])
        let (data, http) = try await joinRequestsTransport(request, label: "invokeCreateJoinRequest")
        guard http.statusCode == 201 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
        return try Self.decodeJoinRequestRow(data)
    }

    public func invokeCancelJoinRequest(requestID: String) async throws {
        try await postEdgeFunction(
            url: SupabaseEndpoint.cancelJoinRequest(baseURL: baseURL),
            body: ["request_id": requestID],
            label: "invokeCancelJoinRequest"
        )
    }

    public func invokeApproveJoinRequest(
        requestID: String,
        encryptedTeamKey: Data
    ) async throws {
        try await postEdgeFunction(
            url: SupabaseEndpoint.approveJoinRequest(baseURL: baseURL),
            body: [
                "request_id": requestID,
                "encrypted_team_key": encryptedTeamKey.base64EncodedString(),
            ],
            label: "invokeApproveJoinRequest"
        )
    }

    public func invokeDeclineJoinRequest(requestID: String) async throws {
        try await postEdgeFunction(
            url: SupabaseEndpoint.declineJoinRequest(baseURL: baseURL),
            body: ["request_id": requestID],
            label: "invokeDeclineJoinRequest"
        )
    }

    public func invokeDeleteInviteToken(code: String) async throws {
        try await postEdgeFunction(
            url: SupabaseEndpoint.deleteInviteToken(baseURL: baseURL),
            body: ["code": code],
            label: "invokeDeleteInviteToken"
        )
    }

    // MARK: - REST GET

    /// Admin lists pending requests for the workspace. RLS join_requests_admin_read
    /// gates by workspace admin (returns empty array for non-admin callers).
    public func listPendingJoinRequests(workspaceID: String) async throws -> [JoinRequest] {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.joinRequestsListPending(baseURL: baseURL, workspaceID: workspaceID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, http) = try await joinRequestsTransport(request, label: "listPendingJoinRequests")
        guard http.statusCode == 200 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
        return try Self.decodeJoinRequestRows(data)
    }

    /// Invitee fetches own request (by request_id; RLS self_read filters by pubkey).
    public func fetchOwnJoinRequest(requestID: String) async throws -> JoinRequest? {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.joinRequestByID(requestID, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, http) = try await joinRequestsTransport(request, label: "fetchOwnJoinRequest")
        guard http.statusCode == 200 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
        let rows = try Self.decodeJoinRequestRows(data)
        return rows.first
    }

    // MARK: - Shared transport + decoding

    private func postEdgeFunction(
        url: URL,
        body: [String: String],
        label: String
    ) async throws {
        let session = try await ensureAuthenticated()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await joinRequestsTransport(request, label: label)
        guard http.statusCode == 200 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
    }

    private func joinRequestsTransport(
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

    /// Wire JSON shape from PostgREST `join_requests` table OR Edge Function
    /// response (create_join_request returns the inserted row in the same shape).
    private struct JoinRequestRow: Decodable {
        let request_id: String
        let workspace_id: String
        let code: String
        let invitee_pubkey: String
        let invitee_display_name: String
        let status: String
        // encrypted_team_key arrives as a hex-prefixed string for `bytea`
        // (`"\\xdeadbeef..."`). Decoded only when status == "approved".
        let encrypted_team_key: String?
        let created_at: String
        let decided_at: String?
        let decided_by_pubkey: String?
    }

    private static func decodeJoinRequestRows(_ data: Data) throws -> [JoinRequest] {
        let rows: [JoinRequestRow]
        do {
            rows = try JSONDecoder().decode([JoinRequestRow].self, from: data)
        } catch {
            throw SupabaseError.decoding(reason: "join_requests rows: \(error)")
        }
        return rows.map(rowToValue)
    }

    private static func decodeJoinRequestRow(_ data: Data) throws -> JoinRequest {
        // Edge Function returns single row directly (not wrapped in array).
        let row: JoinRequestRow
        do {
            row = try JSONDecoder().decode(JoinRequestRow.self, from: data)
        } catch {
            // Fall back to array shape (some PostgREST paths) for resilience.
            if let arr = try? JSONDecoder().decode([JoinRequestRow].self, from: data),
               let first = arr.first {
                return rowToValue(first)
            }
            throw SupabaseError.decoding(reason: "join_request row: \(error)")
        }
        return rowToValue(row)
    }

    private static func rowToValue(_ row: JoinRequestRow) -> JoinRequest {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parse(_ s: String?) -> Date? {
            guard let s = s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        let status = JoinRequest.Status(rawValue: row.status) ?? .pending
        return JoinRequest(
            requestID: row.request_id,
            workspaceID: row.workspace_id,
            code: row.code,
            inviteePubkeyHex: row.invitee_pubkey,
            inviteeDisplayName: row.invitee_display_name,
            status: status,
            encryptedTeamKey: parseByteaHex(row.encrypted_team_key),
            createdAt: parse(row.created_at) ?? Date(),
            decidedAt: parse(row.decided_at),
            decidedByPubkeyHex: row.decided_by_pubkey
        )
    }

    /// PostgREST bytea wire format: `\xHEXHEXHEX...`. Strip prefix + decode.
    /// Returns nil for missing/empty/malformed inputs.
    private static func parseByteaHex(_ raw: String?) -> Data? {
        guard let raw = raw, raw.hasPrefix("\\x") else { return nil }
        let hex = String(raw.dropFirst(2))
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}
