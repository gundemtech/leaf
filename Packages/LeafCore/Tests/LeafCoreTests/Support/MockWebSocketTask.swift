//
//  MockWebSocketTask.swift
//  LeafCoreTests
//
//  Track 5 / S7 — Mock conforming to `URLSessionWebSocketTaskProtocol` for
//  testing `RealtimeWebSocketDriver` without a real WS connection. Mirrors
//  the MockURLProtocol pattern in Support/MockURLProtocol.swift.
//
//  Concurrency: OSAllocatedUnfairLock guards mutable state; lock-protected
//  blocks return continuations or snapshot values and resume continuations
//  OUTSIDE the lock to avoid re-entrant deadlock.
//

import Foundation
import os.lock
@testable import LeafCore

/// Controllable WebSocket task mock. Tests inject an instance via the
/// driver's taskFactory, then push frames via `enqueueIncoming(_:)` and
/// assert on `outgoing` for sends.
final class MockWebSocketTask: URLSessionWebSocketTaskProtocol, @unchecked Sendable {

    private struct State {
        var outgoing: [URLSessionWebSocketTask.Message] = []
        var incomingQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
        var pendingReceives: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
        var isResumed = false
        var cancelCode: URLSessionWebSocketTask.CloseCode?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Public test surface

    var outgoing: [URLSessionWebSocketTask.Message] {
        lock.withLock { $0.outgoing }
    }

    var isResumed: Bool {
        lock.withLock { $0.isResumed }
    }

    var cancelCode: URLSessionWebSocketTask.CloseCode? {
        lock.withLock { $0.cancelCode }
    }

    /// Push an incoming message that the next `receive()` call will return.
    /// If a `receive()` is already awaiting, immediately resumes it.
    func enqueueIncoming(_ message: URLSessionWebSocketTask.Message) {
        let continuation = lock.withLock { state -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if !state.pendingReceives.isEmpty {
                return state.pendingReceives.removeFirst()
            } else {
                state.incomingQueue.append(.success(message))
                return nil
            }
        }
        continuation?.resume(returning: message)
    }

    /// Push a text-frame string message (most common case).
    func enqueueIncomingString(_ s: String) {
        enqueueIncoming(.string(s))
    }

    /// Push an error that the next `receive()` will throw.
    func enqueueError(_ error: Error) {
        let continuation = lock.withLock { state -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if !state.pendingReceives.isEmpty {
                return state.pendingReceives.removeFirst()
            } else {
                state.incomingQueue.append(.failure(error))
                return nil
            }
        }
        continuation?.resume(throwing: error)
    }

    // MARK: - URLSessionWebSocketTaskProtocol

    func resume() {
        lock.withLock { $0.isResumed = true }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let continuations = lock.withLock { state -> [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] in
            state.cancelCode = closeCode
            let c = state.pendingReceives
            state.pendingReceives.removeAll()
            return c
        }
        for c in continuations {
            c.resume(throwing: URLError(.cancelled))
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { $0.outgoing.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            let immediate = lock.withLock { state -> Result<URLSessionWebSocketTask.Message, Error>? in
                if !state.incomingQueue.isEmpty {
                    return state.incomingQueue.removeFirst()
                } else {
                    state.pendingReceives.append(c)
                    return nil
                }
            }
            if let result = immediate {
                c.resume(with: result)
            }
        }
    }
}
