// Track-6 P1 Phase G — end-to-end test that invokes the `leaf-hook-bridge`
// binary as a subprocess, sends JSON via stdin, and verifies the listener
// receives the expected envelope on the unix-domain socket.
//
// The production listener (`ClaudeCodeHookSocketListener`) is moat and
// covered by separate tests in LeafCorePrivateTests. This test uses a
// raw POSIX socket listener inline so the bridge can be tested without
// a LeafCorePrivate dependency.

import XCTest

#if canImport(Darwin)
import Darwin
#endif

final class HookBridgeTests: XCTestCase {
    private var tempDir: URL!
    private var socketPath: String!

    override func setUp() async throws {
        // /tmp/ to stay well under sun_path 104-char limit on macOS.
        tempDir = URL(
            fileURLWithPath: "/tmp/leaf-bridge-test-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        socketPath = tempDir.appendingPathComponent("hooks.sock").path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - End-to-end

    /// Bridge subprocess writes a single envelope to the socket; listener picks
    /// it up; envelope JSON shape matches contract.
    func testBridgeSendsEnvelopeToSocketWithCorrectShape() throws {
        let listener = try TestListener(socketPath: socketPath)
        try listener.start()
        defer { listener.stop() }

        let stdinPayload = #"{"session_id":"S","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let result = try invokeBridge(
            eventName: "PostToolUse",
            stdin: stdinPayload,
            socketOverride: socketPath
        )
        XCTAssertEqual(result.exitCode, 0)

        // Wait briefly for listener thread to flush the line buffer.
        try waitForListenerToReceive(listener, count: 1, timeout: 1.0)

        let received = listener.snapshot()
        XCTAssertEqual(received.count, 1)
        let line = received[0]
        // Parse envelope JSON.
        let data = Data(line.utf8)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["event_name"] as? String, "PostToolUse")
        XCTAssertEqual(json["payload_json"] as? String, stdinPayload)
        XCTAssertNotNil(json["ts_ms"])
        // ts_ms is current wall-clock-ish — sanity check it's a recent ms-since-epoch.
        let ts = json["ts_ms"] as? Int64 ?? Int64(json["ts_ms"] as? Int ?? 0)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThanOrEqual(abs(ts - nowMs), 10_000, "ts_ms within 10s of now")
    }

    /// Bridge exits cleanly when socket is missing (Agent down) — fail-soft.
    func testBridgeFailSoftWhenSocketMissing() throws {
        // Don't start any listener — socket path simply doesn't exist.
        let result = try invokeBridge(
            eventName: "PostToolUse",
            stdin: #"{"tool":"Bash"}"#,
            socketOverride: socketPath
        )
        XCTAssertEqual(result.exitCode, 0, "fail-soft: exit 0 even when socket missing")
        // stderr should mention "connect failed" — observable signal for debug.
        XCTAssertTrue(
            result.stderr.contains("connect"),
            "expected stderr to mention connect failure; got: \(result.stderr)")
    }

    /// Bridge handles empty stdin gracefully (no envelope sent, exit 0).
    func testBridgeExitsCleanlyOnEmptyStdin() throws {
        let listener = try TestListener(socketPath: socketPath)
        try listener.start()
        defer { listener.stop() }

        let result = try invokeBridge(
            eventName: "PostToolUse",
            stdin: "",
            socketOverride: socketPath
        )
        XCTAssertEqual(result.exitCode, 0)

        // Listener should NOT have received anything (give it a moment).
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(listener.snapshot().count, 0)
    }

    /// Bridge invocation latency is bounded (smoke for p99 expectation).
    func testBridgeCompletesFastly() throws {
        let listener = try TestListener(socketPath: socketPath)
        try listener.start()
        defer { listener.stop() }

        let start = Date()
        _ = try invokeBridge(
            eventName: "PostToolUse",
            stdin: #"{"x":1}"#,
            socketOverride: socketPath
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.5,
            "bridge invocation should complete in well under 500ms (target <50ms p99)")
    }

    // MARK: - Helpers

    private struct BridgeResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func invokeBridge(eventName: String, stdin: String, socketOverride: String) throws -> BridgeResult {
        let bridgePath = try bridgeBinaryPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bridgePath)
        process.arguments = [eventName]
        var env = ProcessInfo.processInfo.environment
        env["LEAF_HOOK_SOCKET_OVERRIDE"] = socketOverride
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if !stdin.isEmpty {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return BridgeResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func bridgeBinaryPath() throws -> String {
        let testBundle = Bundle(for: HookBridgeTests.self)
        let buildDir = testBundle.bundleURL.deletingLastPathComponent()
        let candidates = [
            buildDir.appendingPathComponent("leaf-hook-bridge"),
            buildDir.appendingPathComponent("leaf-hook-bridge.product")
                .appendingPathComponent("leaf-hook-bridge"),
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path.path) {
                return path.path
            }
        }
        throw NSError(
            domain: "HookBridgeTests", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "leaf-hook-bridge binary not found near \(buildDir.path); tried: \(candidates.map(\.path))"
            ])
    }

    private func waitForListenerToReceive(_ listener: TestListener, count: Int, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while listener.snapshot().count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThanOrEqual(
            listener.snapshot().count, count,
            "timeout waiting for \(count) lines")
    }
}

// MARK: - Test-local POSIX listener

/// Raw POSIX socket listener — avoids LeafCorePrivate dependency, suitable
/// for end-to-end bridge test in the public test target.
private final class TestListener: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var lines: [String] = []
    private let lock = NSLock()
    private var running = false

    init(socketPath: String) throws {
        self.socketPath = socketPath
    }

    func start() throws {
        // Remove stale socket.
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "TestListener", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: CChar.self)
            var i = 0
            for b in pathBytes {
                buf[i] = CChar(bitPattern: b)
                i += 1
            }
            buf[i] = 0
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrSize)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "TestListener", code: 2)
        }
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw NSError(domain: "TestListener", code: 3)
        }

        listenFD = fd
        running = true

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        // Wake the accept() call by closing the FD.
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if !running { return }
                continue
            }
            // Read until EOF.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var accumulated = Data()
            while true {
                let n = read(clientFD, &buffer, buffer.count)
                if n <= 0 { break }
                accumulated.append(buffer, count: n)
            }
            close(clientFD)
            // Split on \n.
            let allLines = accumulated.split(separator: 0x0A)
            for slice in allLines {
                if let s = String(bytes: slice, encoding: .utf8), !s.isEmpty {
                    lock.lock()
                    lines.append(s)
                    lock.unlock()
                }
            }
        }
    }
}
