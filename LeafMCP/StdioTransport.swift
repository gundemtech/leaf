import Foundation
import LeafMCPProtocol

/// Reads newline-delimited JSON-RPC messages from stdin, writes responses
/// to stdout. Per MCP spec (2025-11-25): stdout MUST contain only valid MCP
/// messages; logging — only to stderr.
actor StdioTransport {
    private let dispatcher: Dispatcher
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(dispatcher: Dispatcher) {
        self.dispatcher = dispatcher
        let e = JSONEncoder()
        // NOT .prettyPrinted — a JSON-RPC message must be single-line.
        e.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = e
        self.decoder = JSONDecoder()
    }

    /// Runs until stdin EOF. Returns naturally on EOF — caller exit(0).
    func serve() async throws {
        let stdin = FileHandle.standardInput
        MCPLog.info("StdioTransport ready — reading stdin lines")

        for try await line in stdin.bytes.lines {
            if Task.isCancelled { break }
            await handleLine(line)
        }

        MCPLog.info("stdin EOF — shutting down")
    }

    private func handleLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: Data(trimmed.utf8))
        } catch {
            // JSON-RPC 2.0: parse error SHOULD include id:null response.
            // Our JSONRPCID does not model null → for the MVP we skip the response.
            // Claude Code handles via transport-level retry/timeout.
            MCPLog.error("Parse error: \(error.localizedDescription)")
            return
        }

        MCPLog.debug("→ method=\(request.method) id=\(String(describing: request.id))")

        guard let response = await dispatcher.dispatch(request) else {
            // Notification (no id) — no response per JSON-RPC 2.0.
            return
        }

        do {
            var payload = try encoder.encode(response)
            payload.append(0x0A)  // '\n' — MCP stdio framing delimiter
            FileHandle.standardOutput.write(payload)
        } catch {
            MCPLog.error("Response encode failed: \(error.localizedDescription)")
        }
    }
}
