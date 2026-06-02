//
//  LoopbackCallbackListener.swift
//  Leaf
//
//  Phase 4.1 — minimal HTTP server on 127.0.0.1:47823 for receiving the OAuth
//  redirect from Linear. Live only for the duration of a single flow:
//  start → first valid callback → respond → cancel.
//

import Foundation
import LeafCore
import Network
import os

nonisolated private let listenerLogger = Logger(subsystem: "tech.gundem.leaf.app", category: "linear-oauth-listener")

enum LoopbackCallbackError: Error {
    case timeout
    case bindFailed(String)
    case parseFailed
    case listenerFailed(String)
}

nonisolated enum LoopbackCallbackListener {
    /// Bind to `127.0.0.1:port`, wait for the first `GET /callback?...`,
    /// send a minimal HTML page, return the `URLComponents` query.
    /// Cancel the listener on timeout or Task cancellation. The caller extracts
    /// the `code`/`state`/`error` parameters from the returned `URLComponents`.
    static func awaitCallback(
        port: UInt16,
        timeout: Duration = .seconds(60),
        providerLabel: String = "Linear"
    ) async throws -> URLComponents {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port.any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(LinearOAuthEndpoints.redirectHost),
            port: nwPort
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackCallbackError.bindFailed(String(describing: error))
        }

        let queue = DispatchQueue(label: "tech.gundem.leaf.linear-callback")
        let coordinator = ResumeOnce()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLComponents, Error>) in
                // Guard against re-resume.
                @Sendable func finish(_ result: Result<URLComponents, Error>) {
                    if coordinator.tryResume() {
                        listener.cancel()
                        continuation.resume(with: result)
                    }
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        listenerLogger.error("listener failed: \(String(describing: error), privacy: .public)")
                        finish(.failure(LoopbackCallbackError.listenerFailed(String(describing: error))))
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { connection in
                    connection.start(queue: queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        if let error {
                            listenerLogger.error("connection receive error: \(String(describing: error), privacy: .public)")
                            connection.cancel()
                            return
                        }
                        guard let data, let line = parseRequestLine(data) else {
                            sendResponse(on: connection, status: "400 Bad Request", body: htmlError("Bad request"))
                            return
                        }

                        // Build URL components from "/callback?<query>" path-and-query.
                        let urlString = "http://\(LinearOAuthEndpoints.redirectHost):\(port)\(line)"
                        guard let components = URLComponents(string: urlString) else {
                            sendResponse(on: connection, status: "400 Bad Request", body: htmlError("Invalid callback URL"))
                            finish(.failure(LoopbackCallbackError.parseFailed))
                            return
                        }

                        // If `error` arrived in the query — still serve the final page
                        // (the user should see a meaningful message in the browser),
                        // then the caller (LinearOAuthService) interprets error/state/code.
                        let isError = components.queryItems?.contains(where: { $0.name == "error" }) ?? false
                        let body = isError ? htmlCancelled(providerLabel: providerLabel) : htmlSuccess(providerLabel: providerLabel)
                        sendResponse(on: connection, status: "200 OK", body: body)
                        finish(.success(components))
                    }
                }

                listener.start(queue: queue)

                // Schedule timeout — async-after on the dispatch queue, finish() guards re-resume.
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                    finish(.failure(LoopbackCallbackError.timeout))
                }
            }
        } onCancel: {
            listener.cancel()
        }
    }

    // MARK: - Internals

    /// Parse first line `GET /callback?<query> HTTP/1.1` and return path-and-query
    /// (`/callback?...`). Returns nil if the format is not an HTTP request.
    private static func parseRequestLine(_ data: Data) -> String? {
        // Read up to first \r\n.
        guard let crlf = data.firstRange(of: Data("\r\n".utf8)),
              let line = String(data: data[..<crlf.lowerBound], encoding: .utf8)
        else { return nil }

        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        guard method == "GET", target.hasPrefix("/") else { return nil }
        return target
    }

    private static func sendResponse(on connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(headers.utf8)
        payload.append(bytes)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func htmlSuccess(providerLabel: String) -> String {
        // Minimal page with no external assets — browsers don't retry
        // if they receive a full Content-Length response.
        let label = htmlEscape(providerLabel)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Leaf — \(label) connected</title></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 4rem; text-align: center;">
        <h2>Leaf is connected to \(label).</h2>
        <p style="color: #666;">You can close this window and return to the app.</p>
        </body></html>
        """
    }

    private static func htmlCancelled(providerLabel: String) -> String {
        let label = htmlEscape(providerLabel)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Leaf — \(label) cancelled</title></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 4rem; text-align: center;">
        <h2>\(label) connection cancelled.</h2>
        <p style="color: #666;">You can close this window and try again from Leaf.</p>
        </body></html>
        """
    }

    /// Minimal HTML-escape for providerLabel (defense in depth — our labels are
    /// hardcoded "Linear"/"Slack", but sanitize anyway so interpolation can't
    /// inject a broken page on future expansion).
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func htmlError(_ message: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Leaf — error</title></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 4rem; text-align: center;">
        <h2>\(message)</h2>
        </body></html>
        """
    }
}

/// Protects against a repeated `continuation.resume` — a race between the normal flow and
/// timeout / cancellation / listener.failed. NSLock for the atomic swap.
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
