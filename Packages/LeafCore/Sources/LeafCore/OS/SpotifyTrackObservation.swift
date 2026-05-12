import Foundation

/// Phase Track-4 S2 — Spotify boundary value type. Same shape as
/// `MusicTrackObservation`. Per-adapter source-grep keeps these distinct
/// so a Music regression cannot leak Spotify-side fields and vice-versa.
public struct SpotifyTrackObservation: AdapterObservation, Hashable {
    public let trackName: String?
    public let artistName: String?
    public let playerState: PlayerState

    public init(trackName: String?, artistName: String?, playerState: PlayerState) {
        self.trackName = trackName
        self.artistName = artistName
        self.playerState = playerState
    }
}
