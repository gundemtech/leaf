// Track-6 P1 — thin native bridge invoked by Claude Code hooks.
// Reads JSON hook payload from stdin, packages into envelope, writes one-line
// JSON to ~/Library/Application Support/Leaf/hooks.sock (Unix domain socket
// where Agent listens). Exit 0 always — fail-soft. If Agent is down / socket
// missing, jsonl floor backfills within 30s. ~50KB binary, ~5ms cold start.
//
// Bridge invocation shape (per claude.com/docs/en/hooks):
//   leaf-hook-bridge <EventName>   # stdin = hook payload JSON
//
// Envelope format written to socket:
//   {"event_name": "<EventName>", "payload_json": "<raw stdin>", "ts_ms": 1715829600000}\n
//
// Privacy: this binary does NOT read or parse payload content. It just forwards
// the raw bytes to Agent. Agent's parser (LeafCorePrivate/ClaudeCodeHookParser)
// applies the ADR-010 allowlist before any field reaches the events table.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

let eventName = CommandLine.arguments.dropFirst().first ?? "Unknown"

// Read stdin to EOF.
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
if stdinData.isEmpty {
    exit(0)  // Empty stdin — nothing to forward. Fail-soft.
}

// Socket path: env override (for tests) or production default.
let socketPath: String = {
    if let override = ProcessInfo.processInfo.environment["LEAF_HOOK_SOCKET_OVERRIDE"], !override.isEmpty {
        return override
    }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/Leaf/hooks.sock"
}()

// Build envelope.
let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
let payloadString = String(data: stdinData, encoding: .utf8) ?? ""
let envelope: [String: Any] = [
    "event_name": eventName,
    "payload_json": payloadString,
    "ts_ms": tsMs
]
guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
    FileHandle.standardError.write(Data("leaf-hook-bridge: envelope encode failed\n".utf8))
    exit(0)
}
var envelopeLine = envelopeData
envelopeLine.append(0x0A)  // \n delimiter

// Connect to Unix domain socket via POSIX. NWConnection's unix-domain support
// is non-trivial and would add async overhead; raw POSIX socket is ~30 lines
// and matches the "thin binary" design goal.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
if fd < 0 {
    FileHandle.standardError.write(Data("leaf-hook-bridge: socket() failed errno=\(errno)\n".utf8))
    exit(0)
}
defer { close(fd) }

// Set 50ms send timeout — bridge target p99.
var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
_ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

// Build sockaddr_un.
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8
let pathLen = pathBytes.count
// sun_path is a fixed-size tuple in C; max 103 chars on macOS.
let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
if pathLen > maxPathLen {
    FileHandle.standardError.write(Data("leaf-hook-bridge: socket path too long (\(pathLen) > \(maxPathLen))\n".utf8))
    exit(0)
}
withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
    let buffer = rawBuffer.bindMemory(to: CChar.self)
    var idx = 0
    for byte in pathBytes {
        buffer[idx] = CChar(bitPattern: byte)
        idx += 1
    }
    buffer[idx] = 0  // null terminator
}

let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
let connectResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fd, sockPtr, addrSize)
    }
}
if connectResult < 0 {
    // Socket missing / Agent down — fail-soft. jsonl floor backfills.
    FileHandle.standardError.write(Data("leaf-hook-bridge: connect failed errno=\(errno)\n".utf8))
    exit(0)
}

// Write the envelope line.
envelopeLine.withUnsafeBytes { rawBuffer in
    let bytesWritten = write(fd, rawBuffer.baseAddress, rawBuffer.count)
    if bytesWritten < 0 {
        FileHandle.standardError.write(Data("leaf-hook-bridge: write failed errno=\(errno)\n".utf8))
    }
}

exit(0)
