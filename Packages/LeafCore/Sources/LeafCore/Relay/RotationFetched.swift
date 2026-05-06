//
//  RotationFetched.swift
//  LeafCore
//
//  Phase 5.3.C — Public response value type for `RelayClient.fetchPendingRotations`.
//  Element of the array returned from GET /v1/key-rotation/by-peer/:peer_pubkey_hex.
//  Caller (5.3.E `RotationFetchService`) iterates → derives wrapKey → unwraps via
//  `RotationBlobCodec.decode` → installs new teamKey → ACKs via DELETE /v1/key-rotation/:rotation_id.
//

import Foundation

public struct RotationFetched: Sendable, Hashable {
    public let rotationID: String
    public let blob: Data
    public let expiresAtMs: Int64
    public init(rotationID: String, blob: Data, expiresAtMs: Int64) {
        self.rotationID = rotationID
        self.blob = blob
        self.expiresAtMs = expiresAtMs
    }
}
