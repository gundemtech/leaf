import XCTest
import Foundation
import CryptoKit
@testable import LeafCore

final class RotationFetchServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: LeafCore.Database!
    private var relayClient: RelayClient!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-rotfetchsvc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RotationFetchServiceMockURLProtocol.self]
        relayClient = RelayClient(
            baseURL: URL(string: "https://test.example.com")!,
            urlSession: URLSession(configuration: config)
        )
    }

    override func tearDown() async throws {
        RotationFetchServiceMockURLProtocol.handler = nil
        RotationFetchServiceMockURLProtocol.networkError = nil
        RotationFetchServiceMockURLProtocol.lastRequest = nil
        db = nil
        relayClient = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Scaffold

    func testInitConstructs() {
        let svc = RotationFetchService(
            database: db,
            relayClient: relayClient,
            rotationKDF: UnimplementedRotationKDF(),
            rotationBlobCodec: UnimplementedRotationBlobCodec(),
            keystoreRoot: keystoreRoot
        )
        _ = svc  // just constructable
    }
}

// MARK: - Mock URLProtocol (file-local)

final class RotationFetchServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let err = Self.networkError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lastRequest = request
        do {
            let (resp, data) = try handler(request, Data())
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data = data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
