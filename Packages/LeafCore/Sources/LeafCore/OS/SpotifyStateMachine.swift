import Foundation

/// Phase Track-4 S2 — pure transition detector for Spotify. Emits
/// `spotify_track_changed` when track / artist / player state differs.
/// Distinct type from `MusicStateMachine` so per-adapter source-grep
/// keeps the surfaces strictly separated.
public struct SpotifyStateMachine: Sendable, Hashable {
    private var prev: SpotifyTrackObservation?

    public init() {}

    public mutating func observe(_ obs: SpotifyTrackObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        let changed: Bool = {
            guard let p = prev else { return true }
            return p.trackName != obs.trackName
                || p.artistName != obs.artistName
                || p.playerState != obs.playerState
        }()
        guard changed else { return [] }
        var payload: [String: String] = [
            "event_kind": "spotify_track_changed",
            "player_state": obs.playerState.rawValue
        ]
        if let t = obs.trackName { payload["track"] = t }
        if let a = obs.artistName { payload["artist"] = a }
        return [RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.spotify.client",
            payload: payload
        )]
    }
}
