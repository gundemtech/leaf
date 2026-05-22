// Phase 5.5.C — PendingInvitesService unit tests. RelayClient stubbed via
// URLProtocol injection (mirror RelayClientTests pattern).

import XCTest
import Foundation
@testable import LeafCore

private final class PendingMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PendingInvitesServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let stubBase = URL(string: "https://stub.example")!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-pending-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        PendingMockURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        PendingMockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeDatabase() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeRelayClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingMockURLProtocol.self]
        return RelayClient(baseURL: stubBase, urlSession: URLSession(configuration: config))
    }

    private func httpResponse(_ status: Int, url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? stubBase,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func samplePending(
        token: String,
        workspaceID: String = "wkspc_test",
        otp: String = "123456",
        createdAtMs: Int64 = 1_700_000_000_000
    ) -> PendingInvite {
        PendingInvite(
            token: token,
            workspaceID: workspaceID,
            otp: otp,
            inviteePubkeyHex: String(repeating: "a", count: 64),
            inviteeDisplayNameHint: nil,
            createdAtMs: createdAtMs,
            expiresAtMs: createdAtMs + 24 * 60 * 60 * 1000,
            status: .pending,
            lastPolledAtMs: nil
        )
    }

    private func makeService(
        database: LeafCore.Database,
        nowMs: Int64 = 1_700_000_005_000
    ) -> PendingInvitesService {
        PendingInvitesService(
            database: database,
            relayClient: makeRelayClient(),
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) }
        )
    }

    // MARK: - loadVisible

    func testLoadVisibleFiltersConsumedAndSweepsExpired() throws {
        let db = try makeDatabase()
        let nowMs: Int64 = 1_700_000_000_000
        try db.insertPendingInvite(samplePending(
            token: "tlive______________________________",
            createdAtMs: nowMs
        ))
        try db.insertPendingInvite(samplePending(
            token: "texpired___________________________",
            createdAtMs: nowMs - 48 * 60 * 60 * 1000
        ))
        try db.insertPendingInvite(samplePending(
            token: "tconsumed__________________________",
            createdAtMs: nowMs
        ))
        try db.updatePendingInviteStatus(
            token: "tconsumed__________________________",
            status: .consumed
        )

        let svc = makeService(database: db, nowMs: nowMs)
        let visible = try svc.loadVisible()
        let tokens = Set(visible.map(\.token))
        XCTAssertTrue(tokens.contains("tlive______________________________"))
        XCTAssertTrue(tokens.contains("texpired___________________________"))
        XCTAssertFalse(tokens.contains("tconsumed__________________________"))

        let expiredRow = try XCTUnwrap(visible.first { $0.token == "texpired___________________________" })
        XCTAssertEqual(expiredRow.status, .expired, "loadVisible's sweep persisted .expired transition")
    }

    // MARK: - pollPending

    func testPollPending200KeepsPendingAndStampsLastPolledAt() async throws {
        let db = try makeDatabase()
        let nowMs: Int64 = 1_700_000_000_000
        try db.insertPendingInvite(samplePending(
            token: "tk1________________________________",
            createdAtMs: nowMs
        ))

        PendingMockURLProtocol.handler = { req in
            // Response body matches RelayClient.parseInviteFetched: { blob: <base64url>, expires_at_ms: Int64 }
            let body = #"{"blob":"AQID","expires_at_ms":1700000099999}"#.data(using: .utf8)!
            return (HTTPURLResponse(
                url: req.url ?? URL(string: "https://stub.example")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!, body)
        }

        let svc = makeService(database: db, nowMs: nowMs + 5_000)
        let outcome = try await svc.pollPending()
        XCTAssertEqual(outcome, PollOutcome(consumed: 0, stillPending: 1, networkErrors: 0))

        let rows = try db.readAllPendingInvitesByStatus(.pending)
        XCTAssertEqual(rows.first?.lastPolledAtMs, nowMs + 5_000)
    }

    func testPollPending404MarksConsumed() async throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "tk2________________________________"))
        PendingMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = makeService(database: db)
        let outcome = try await svc.pollPending()
        XCTAssertEqual(outcome, PollOutcome(consumed: 1, stillPending: 0, networkErrors: 0))

        XCTAssertTrue(try db.readAllPendingInvitesByStatus(.pending).isEmpty)
        XCTAssertEqual(try db.readAllPendingInvitesByStatus(.consumed).first?.token,
                       "tk2________________________________")
    }

    func testPollPendingMixedOutcomes() async throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "tkkeep_____________________________"))
        try db.insertPendingInvite(samplePending(token: "tkconsume__________________________"))
        try db.insertPendingInvite(samplePending(token: "tkneterr___________________________"))

        PendingMockURLProtocol.handler = { req in
            let last = req.url?.lastPathComponent ?? ""
            switch last {
            case "tkkeep_____________________________":
                let body = #"{"blob":"AQID","expires_at_ms":1700000099999}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, body)
            case "tkconsume__________________________":
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data())
            case "tkneterr___________________________":
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data())
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
        }

        let svc = makeService(database: db)
        let outcome = try await svc.pollPending()
        XCTAssertEqual(outcome, PollOutcome(consumed: 1, stillPending: 1, networkErrors: 1))
    }

    // MARK: - revoke

    func testRevokeBestEffort204() async throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "trev1______________________________"))
        PendingMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = makeService(database: db)
        try await svc.revoke(token: "trev1______________________________")

        let row = try XCTUnwrap(try db.readAllPendingInvites().first {
            $0.token == "trev1______________________________"
        })
        XCTAssertEqual(row.status, .revoked)
    }

    func testRevokeRelayFailureLocalTruth() async throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "trev2______________________________"))
        PendingMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = makeService(database: db)
        try await svc.revoke(token: "trev2______________________________")  // best-effort — не throws

        XCTAssertEqual(
            try db.readAllPendingInvites().first { $0.token == "trev2______________________________" }?.status,
            .revoked
        )
    }

    func testRevokeLocalSyncFlipsBeforeRelayCall() throws {
        // Spec D4 — DB write must complete synchronously without awaiting relay.
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "tlocal_____________________________"))

        let svc = makeService(database: db)
        try svc.revokeLocal(token: "tlocal_____________________________")

        let row = try XCTUnwrap(try db.readAllPendingInvites().first {
            $0.token == "tlocal_____________________________"
        })
        XCTAssertEqual(row.status, .revoked)
    }

    func testTryRelayDeleteNeverThrows() async throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "tdel_______________________________"))
        PendingMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = makeService(database: db)
        // Just calling — no try because tryRelayDelete is non-throwing best-effort.
        await svc.tryRelayDelete(token: "tdel_______________________________")
        // No-op success criterion: completes without throwing.
    }

    func testRevokeNonexistentTokenIdempotent() async throws {
        let db = try makeDatabase()
        PendingMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        let svc = makeService(database: db)
        try await svc.revoke(token: "tkneverexisted_____________________")
        // No throw — DB updateStatus is silent no-op semantics per PendingInvitesStore.
    }

    // MARK: - dismiss

    func testDismissDeletesRow() throws {
        let db = try makeDatabase()
        try db.insertPendingInvite(samplePending(token: "tdis1______________________________"))

        let svc = makeService(database: db)
        try svc.dismiss(token: "tdis1______________________________")

        XCTAssertTrue(try db.readAllPendingInvites().isEmpty)
    }
}
