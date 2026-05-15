//
//  SupabaseClient+CrossPost.swift
//  LeafCore
//
//  Track 5 / S6 — Cross-post (Slack + Linear) Edge Function wire layer.
//
//  Both methods POST to Edge Functions that forward the caller's per-provider
//  OAuth user token to Slack chat.postMessage or Linear GraphQL issueCreate.
//  Tokens are passed in the request body and never persisted or logged on the
//  Edge Function side (defence-in-depth: function verifies JWT pubkey claim
//  matches direct_messages.sender_pubkey before forwarding).
//
//  Pattern mirrors triggerAPNsPush from S4: ensureAuthenticated() bootstrap,
//  JWT-bearer Authorization header, identityClaimMissing guard on
//  session.pubkeyClaim, 401/403/5xx mapped via SupabaseError.fromStatus.
//

import Foundation

// MARK: - Wire response shapes

/// Result of forwarding a Slack chat.postMessage via the slack_post Edge Function.
/// `ok == true` corresponds to a Slack API success (with `ts` and `channelID`).
/// `ok == false` carries Slack's error code (e.g. "channel_not_found",
/// "rate_limited"). On `rate_limited`, `retryAfterSeconds` carries the
/// Retry-After header value from Slack 429 — UI surfaces "retry in Ns" (A14).
public struct SlackCrossPostResult: Sendable, Equatable {
    public let ok: Bool
    public let ts: String?
    public let channelID: String?
    public let error: String?
    public let retryAfterSeconds: Int?

    public init(ok: Bool, ts: String?, channelID: String?, error: String?, retryAfterSeconds: Int?) {
        self.ok = ok
        self.ts = ts
        self.channelID = channelID
        self.error = error
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Result of forwarding a Linear issueCreate via the linear_create_issue Edge
/// Function. Success path populates `issueID` (internal Linear UUID),
/// `identifier` (human-readable "LEA-42"), and `url` (deep-link). Error path
/// preserves Linear's error code as `error` ("authentication_error",
/// "ratelimited", "linear_api_error", etc.).
public struct LinearCrossPostResult: Sendable, Equatable {
    public let ok: Bool
    public let issueID: String?
    public let identifier: String?
    public let url: String?
    public let error: String?

    public init(ok: Bool, issueID: String?, identifier: String?, url: String?, error: String?) {
        self.ok = ok
        self.issueID = issueID
        self.identifier = identifier
        self.url = url
        self.error = error
    }
}

// MARK: - Cross-post methods

extension SupabaseClient {

    /// POST to slack_post Edge Function — forwards Slack user token + payload
    /// to https://slack.com/api/chat.postMessage. Token transits the function
    /// in request body only; never persisted, never logged on Edge side.
    ///
    /// - Parameters:
    ///   - workspaceID: Leaf workspace UUID (binds to direct_messages row).
    ///   - messageID: direct_messages row UUID this cross-post attaches to
    ///     (server verifies caller is sender of this row before forwarding).
    ///   - channelID: Slack channel ID (e.g. "C12345").
    ///   - slackPayload: pre-built hybrid text + Block Kit payload dict
    ///     (built by `CrossPostPayloadBuilder.slackPayload`).
    ///   - slackUserToken: sender's Slack OAuth user token. Out of scope on
    ///     Edge Function after fetch returns.
    public func triggerSlackPost(
        workspaceID: UUID,
        messageID: UUID,
        channelID: String,
        slackPayload: sending [String: Any],
        slackUserToken: String
    ) async throws -> SlackCrossPostResult {
        let session = try await ensureAuthenticated()
        guard let pubkey = session.pubkeyClaim, !pubkey.isEmpty else {
            throw SupabaseError.identityClaimMissing
        }
        // Pubkey claim presence verified above; the Edge Function re-verifies
        // it server-side against direct_messages.sender_pubkey. We don't send
        // pubkey in the body — function extracts it from the JWT itself.
        _ = pubkey

        let url = SupabaseEndpoint.slackPost(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let body: [String: Any] = [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "message_id": messageID.uuidString.lowercased(),
            "channel_id": channelID,
            "slack_payload": slackPayload,
            "slack_user_token": slackUserToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await crossPostTransport(request, label: "triggerSlackPost")
        guard http.statusCode == 200 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
        struct Body: Decodable {
            let ok: Bool
            let ts: String?
            let channel_id: String?
            let error: String?
            let retry_after_seconds: Int?
        }
        let parsed: Body
        do {
            parsed = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw SupabaseError.decoding(reason: "triggerSlackPost: \(error)")
        }
        return SlackCrossPostResult(
            ok: parsed.ok,
            ts: parsed.ts,
            channelID: parsed.channel_id,
            error: parsed.error,
            retryAfterSeconds: parsed.retry_after_seconds
        )
    }

    /// POST to linear_create_issue Edge Function — forwards Linear OAuth token
    /// + IssueCreateInput fields to https://api.linear.app/graphql.
    ///
    /// - Parameters:
    ///   - workspaceID: Leaf workspace UUID.
    ///   - messageID: direct_messages row UUID this cross-post attaches to.
    ///   - teamID: Linear team ID where the issue will be created.
    ///   - idempotencyKey: caller-generated UUIDv4 used as Linear's
    ///     `IssueCreateInput.id`. Retrying the same request yields the same
    ///     issue (A5 retry-safety per Linear API research).
    ///   - title: 1..=200 char title; Edge Function rejects empty / oversize.
    ///   - description: free-form markdown description.
    ///   - assigneeID: optional Linear user ID. When nil, OMITTED from the
    ///     request body (Edge Function treats undefined/null as no assignee).
    ///   - linearUserToken: sender's Linear OAuth access token. Out of scope
    ///     on Edge Function after fetch returns.
    public func triggerLinearCreate(
        workspaceID: UUID,
        messageID: UUID,
        teamID: String,
        idempotencyKey: UUID,
        title: String,
        description: String,
        assigneeID: String?,
        linearUserToken: String
    ) async throws -> LinearCrossPostResult {
        let session = try await ensureAuthenticated()
        guard let pubkey = session.pubkeyClaim, !pubkey.isEmpty else {
            throw SupabaseError.identityClaimMissing
        }
        _ = pubkey

        let url = SupabaseEndpoint.linearCreateIssue(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        var body: [String: Any] = [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "message_id": messageID.uuidString.lowercased(),
            "team_id": teamID,
            "idempotency_key": idempotencyKey.uuidString.lowercased(),
            "title": title,
            "description": description,
            "linear_user_token": linearUserToken,
        ]
        // Omit assignee_id entirely when nil — Edge Function checks for
        // undefined/null and treats as no assignee. Passing JSON null is
        // technically equivalent but explicit omission keeps the wire shape
        // tight and survives Edge Function type-narrowing changes.
        if let assigneeID, !assigneeID.isEmpty {
            body["assignee_id"] = assigneeID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await crossPostTransport(request, label: "triggerLinearCreate")
        guard http.statusCode == 200 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
        struct Body: Decodable {
            let ok: Bool
            let issue_id: String?
            let identifier: String?
            let url: String?
            let error: String?
        }
        let parsed: Body
        do {
            parsed = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw SupabaseError.decoding(reason: "triggerLinearCreate: \(error)")
        }
        return LinearCrossPostResult(
            ok: parsed.ok,
            issueID: parsed.issue_id,
            identifier: parsed.identifier,
            url: parsed.url,
            error: parsed.error
        )
    }

    // MARK: - Internal helpers

    /// Local transport wrapper — keeps cross-post extension self-contained so
    /// the file doesn't depend on the private DM-extension transport helper.
    /// Identical shape to the DM extension's helper for behavioural parity.
    private func crossPostTransport(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
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
