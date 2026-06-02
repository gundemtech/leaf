//
//  RelayClient.swift
//  LeafCore
//
//  Phase 5.2.D — HTTP wire layer for invite-relay endpoints (POST/GET/DELETE
//  /v1/invite/*). Actor — concurrency boundary; URLSession injection (default
//  `.shared`) — standard test-stub pattern (see SlackTokenRefresher / 4.4).
//
//  Status mapping:
//   - 201 (POST) → RelayInviteToken
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

    public init(
        // Reason: compile-time-constant URL literal — `URL(string:)` of a static well-formed URL never returns nil.
        // swiftlint:disable:next force_unwrapping
        baseURL: URL = URL(string: "https://oauth.gundem.tech")!,
        urlSession: URLSession = .leafEphemeral()
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func postInvite(memberPubkeyHex: String,
                           blob: Data,
                           expiresAtMs: Int64) async throws -> RelayInviteToken {
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

    // MARK: - Rotation (Phase 5.3.C)
    //
    // Wire format: spec docs/superpowers/specs/2026-05-04-phase-5-3-C-relay-rotation.md §3.
    //
    // Status mapping:
    //   - 201 (POST)    → RotationToken
    //   - 200 (GET)     → [RotationFetched]  (blob base64url-decoded per element)
    //   - 204 (DELETE)  → success (no body)
    //   - 400 → LeafError.rotationRequestRejected("bad-input")
    //   - 405 → LeafError.rotationRequestRejected("method")
    //   - 413 → LeafError.rotationRequestRejected("size")
    //   - 415 → LeafError.rotationRequestRejected("media-type")
    //   - 500 → LeafError.relayUnreachable("server-error")
    //   - URLSession throw → LeafError.relayUnreachable("transport")
    //   - unparseable / unexpected → LeafError.relayUnreachable("malformed-response")

    public func postRotationBlob(peerPubkeyHex: String,
                                 blob: Data,
                                 expiresAtMs: Int64) async throws -> RotationToken {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/key-rotation"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "peer_pubkey_hex": peerPubkeyHex,
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
            return try parseRotationToken(from: data)
        case 400:
            throw LeafError.rotationRequestRejected(reason: "bad-input")
        case 405:
            throw LeafError.rotationRequestRejected(reason: "method")
        case 413:
            throw LeafError.rotationRequestRejected(reason: "size")
        case 415:
            throw LeafError.rotationRequestRejected(reason: "media-type")
        case 500:
            throw LeafError.relayUnreachable(reason: "server-error")
        default:
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
    }

    public func fetchPendingRotations(forPeerPubkeyHex peerPubkeyHex: String) async throws -> [RotationFetched] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/key-rotation/by-peer/\(peerPubkeyHex)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await send(request)

        switch http.statusCode {
        case 200:
            return try parseRotationsArray(from: data)
        case 400:
            throw LeafError.rotationRequestRejected(reason: "bad-input")
        case 405:
            throw LeafError.rotationRequestRejected(reason: "method")
        case 500:
            throw LeafError.relayUnreachable(reason: "server-error")
        default:
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
    }

    public func ackRotation(rotationID: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/key-rotation/\(rotationID)"))
        request.httpMethod = "DELETE"
        let (_, http) = try await send(request)
        switch http.statusCode {
        case 204:
            return
        case 405:
            throw LeafError.rotationRequestRejected(reason: "method")
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

    private func parseInviteToken(from data: Data) throws -> RelayInviteToken {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        let expiresAtMs = try parseInt64(obj["expires_at_ms"])
        return RelayInviteToken(value: token, expiresAtMs: expiresAtMs)
    }

    private func parseInviteFetched(from data: Data) throws -> InviteFetched {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blobStr = obj["blob"] as? String,
              let blobBytes = Data(base64URLNoPad: blobStr)
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        let expiresAtMs = try parseInt64(obj["expires_at_ms"])
        return InviteFetched(blob: blobBytes, expiresAtMs: expiresAtMs)
    }

    private func parseInt64(_ value: Any?) throws -> Int64 {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? NSNumber { return v.int64Value }
        throw LeafError.relayUnreachable(reason: "malformed-response")
    }

    private func parseRotationToken(from data: Data) throws -> RotationToken {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["rotation_id"] as? String
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        let expiresAtMs = try parseInt64(obj["expires_at_ms"])
        return RotationToken(value: token, expiresAtMs: expiresAtMs)
    }

    private func parseRotationsArray(from data: Data) throws -> [RotationFetched] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["rotations"] as? [[String: Any]]
        else {
            throw LeafError.relayUnreachable(reason: "malformed-response")
        }
        var result: [RotationFetched] = []
        result.reserveCapacity(arr.count)
        for item in arr {
            guard let rotationID = item["rotation_id"] as? String,
                  let blobStr = item["blob"] as? String,
                  let blobBytes = Data(base64URLNoPad: blobStr)
            else {
                throw LeafError.relayUnreachable(reason: "malformed-response")
            }
            let expiresAtMs = try parseInt64(item["expires_at_ms"])
            result.append(RotationFetched(rotationID: rotationID,
                                          blob: blobBytes,
                                          expiresAtMs: expiresAtMs))
        }
        return result
    }
}

/// Phase 5.5 / pre-Track 5 Cloudflare relay invite token. Replaced by Track 5
/// `InviteToken` (M027) and Supabase magic-link flow; this struct stays for
/// Phase 5.5 `RelayClient` test coverage and is deprecated for runtime use.
public struct RelayInviteToken: Sendable, Hashable {
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
