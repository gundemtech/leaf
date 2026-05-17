//
//  LoopbackCallbackListener.swift
//  Leaf
//
//  Phase 4.1 — minimal HTTP server на 127.0.0.1:47823 для приёма OAuth
//  redirect от Linear. Live только на время одного flow:
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
    /// Bind на `127.0.0.1:port`, ждать первого `GET /callback?...`,
    /// послать минимальную HTML-страницу, вернуть `URLComponents` query.
    /// Cancel listener по timeout либо Task cancellation. Caller достаёт
    /// `code`/`state`/`error` параметры из вернувшегося `URLComponents`.
    ///
    /// `port == 0` requests a kernel-assigned ephemeral port (Track-6 P4 Google
    /// Calendar — Google has no fixed-port relay constraint, ephemeral is more
    /// robust under concurrent flows). When provided, `onPortAssigned` is
    /// invoked exactly once with the actually-bound port — caller plumbs that
    /// number into the OAuth `redirect_uri` query param before opening the
    /// browser. Linear/Slack pass fixed ports and ignore this callback.
    static func awaitCallback(
        port: UInt16,
        timeout: Duration = .seconds(60),
        providerLabel: String = "Linear",
        onPortAssigned: (@Sendable (UInt16) -> Void)? = nil
    ) async throws -> URLComponents {
        // port == 0 → ask the kernel for an ephemeral port (NWEndpoint.Port.any).
        // Non-zero non-bindable values fall back to `.any` as well to mirror
        // prior behaviour.
        let nwPort: NWEndpoint.Port =
            port == 0
            ? .any
            : (NWEndpoint.Port(rawValue: port) ?? .any)
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
                // Гард на пере-resume.
                @Sendable func finish(_ result: Result<URLComponents, Error>) {
                    if coordinator.tryResume() {
                        listener.cancel()
                        continuation.resume(with: result)
                    }
                }

                // Capture the kernel-assigned port exactly once when listener
                // transitions to `.ready`. We re-read `listener.port` (not the
                // requested one) so ephemeral-port callers (Track-6 P4) get
                // the real number to put into the OAuth redirect_uri.
                let portFiredOnce = ResumeOnce()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if portFiredOnce.tryResume(), let onPortAssigned,
                            let assigned = listener.port?.rawValue
                        {
                            onPortAssigned(assigned)
                        }
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
                            listenerLogger.error(
                                "connection receive error: \(String(describing: error), privacy: .public)")
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
                            sendResponse(
                                on: connection, status: "400 Bad Request", body: htmlError("Invalid callback URL"))
                            finish(.failure(LoopbackCallbackError.parseFailed))
                            return
                        }

                        // Если в query пришёл `error` — всё равно serve финальную страницу
                        // (юзер должен видеть осмысленное сообщение в браузере),
                        // дальше caller (LinearOAuthService) интерпретирует error/state/code.
                        let isError = components.queryItems?.contains(where: { $0.name == "error" }) ?? false
                        let body =
                            isError
                            ? htmlCancelled(providerLabel: providerLabel) : htmlSuccess(providerLabel: providerLabel)
                        sendResponse(on: connection, status: "200 OK", body: body)
                        finish(.success(components))
                    }
                }

                listener.start(queue: queue)

                // Schedule timeout — async-after на dispatch queue, finish() guards re-resume.
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
    /// (`/callback?...`). Returns nil если формат не HTTP request.
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
        connection.send(
            content: payload,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private static func htmlSuccess(providerLabel: String) -> String {
        // Минимальная страница без external assets — браузеры не делают retry,
        // если получают full Content-Length response.
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

    /// Минимальный HTML-escape для providerLabel (defense in depth — labels у нас
    /// hardcoded "Linear"/"Slack", но всё равно sanitize чтобы interpolation не
    /// инжектил ломанную страницу при future expansion).
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

/// Защита от повторного `continuation.resume` — race между normal flow и
/// timeout / cancellation / listener.failed. NSLock для атомарного swap'а.
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
