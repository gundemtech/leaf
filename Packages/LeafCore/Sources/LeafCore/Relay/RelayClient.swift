//
//  RelayClient.swift
//  LeafCore
//
//  Phase 5.2.D — HTTP wire layer для invite-relay endpoints (POST/GET/DELETE
//  /v1/invite/*). Actor — concurrency boundary; URLSession injection (default
//  `.shared`) — стандартный test-stub pattern (см. SlackTokenRefresher / 4.4).
//
//  Status mapping:
//   - 201 (POST) → InviteToken
//   - 200 (GET)  → InviteFetched (blob base64url-decoded)
//   - 204 (DELETE) → success (no body)
//   - 400 → LeafError.inviteRequestRejected("bad-input")
//   - 404 (GET) → LeafError.inviteNotFound
//   - 405 → LeafError.inviteRequestRejected("method")
//   - 413 → LeafError.inviteRequestRejected("size")
//   - 415 → LeafError.inviteRequestRejected("media-type")
//   - 500 → LeafError.relayUnreachable("server-error")
//   - URLSession throw → LeafError.relayUnreachable("transport")
//   - unparseable / unexpected → LeafError.relayUnreachable("malformed-response")
//

import Foundation

public actor RelayClient: Sendable {
    public let baseURL: URL
    private let urlSession: URLSession

    public init(baseURL: URL = URL(string: "https://oauth.gundem.tech")!,
                urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func postInvite(memberPubkeyHex: String,
                           blob: Data,
                           expiresAtMs: Int64) async throws -> InviteToken {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invite"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "member_pubkey_hex": memberPubkeyHex,
            "blob": blob.base64URLNoPad,
            "expires_at_ms": expiresAtMs
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }

        let (data, http) = try await send(request)

        switch http.statusCode {
        case 201:
            return try parseInviteToken(from: data)
        case 400:
            throw LeafError.inviteRequestRejected(reason: "bad-input")
        case 405:
            throw LeafError.inviteRequestRejected(reason: "method")
        case 413:
            throw LeafError.inviteRequestRejected(reason: "size")
        case 415:
            throw LeafError.inviteRequestRejected(reason: "media-type")
        case 500:
            throw LeafError.relayUnreachable(reason: "server-error")
        default:
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
    }

    public func getInvite(token: String) async throws -> InviteFetched {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invite/\(token)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await send(request)

        switch http.statusCode {
        case 200:
            return try parseInviteFetched(from: data)
        case 404:
            throw LeafError.inviteNotFound
        case 405:
            throw LeafError.inviteRequestRejected(reason: "method")
        case 500:
            throw LeafError.relayUnreachable(reason: "server-error")
        default:
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
    }

    public func deleteInvite(token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invite/\(token)"))
        request.httpMethod = "DELETE"

        let (_, http) = try await send(request)

        switch http.statusCode {
        case 204:
            return
        case 405:
            throw LeafError.inviteRequestRejected(reason: "method")
        case 500:
            throw LeafError.relayUnreachable(reason: "server-error")
        default:
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
    }

    // MARK: - Internals

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LeafError.relayUnreachable(reason: "transport")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        return (data, http)
    }

    private func parseInviteToken(from data: Data) throws -> InviteToken {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String,
              let expiresAny = obj["expires_at_ms"]
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        let expiresAtMs: Int64
        if let v = expiresAny as? Int64 {
            expiresAtMs = v
        } else if let v = expiresAny as? Int {
            expiresAtMs = Int64(v)
        } else if let v = expiresAny as? NSNumber {
            expiresAtMs = v.int64Value
        } else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        return InviteToken(value: token, expiresAtMs: expiresAtMs)
    }

    private func parseInviteFetched(from data: Data) throws -> InviteFetched {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blobStr = obj["blob"] as? String,
              let blobBytes = Data(base64URLNoPad: blobStr),
              let expiresAny = obj["expires_at_ms"]
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        let expiresAtMs: Int64
        if let v = expiresAny as? Int64 {
            expiresAtMs = v
        } else if let v = expiresAny as? Int {
            expiresAtMs = Int64(v)
        } else if let v = expiresAny as? NSNumber {
            expiresAtMs = v.int64Value
        } else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        return InviteFetched(blob: blobBytes, expiresAtMs: expiresAtMs)
    }
}

public struct InviteToken: Sendable, Hashable {
    public let value: String
    public let expiresAtMs: Int64
    public init(value: String, expiresAtMs: Int64) {
        self.value = value
        self.expiresAtMs = expiresAtMs
    }
}

public struct InviteFetched: Sendable {
    public let blob: Data
    public let expiresAtMs: Int64
    public init(blob: Data, expiresAtMs: Int64) {
        self.blob = blob
        self.expiresAtMs = expiresAtMs
    }
}

// MARK: - base64url (no-pad)

extension Data {
    var base64URLNoPad: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLNoPad string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
