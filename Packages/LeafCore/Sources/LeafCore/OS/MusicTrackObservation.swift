import Foundation

public enum PlayerState: String, Sendable, Codable, Hashable {
    case playing
    case paused
    case stopped
}

/// Phase Track-4 S2 — Apple Music boundary value type. Track name + artist +
/// player state. Lyrics, playlist details, library metadata never cross.
public struct MusicTrackObservation: AdapterObservation, Hashable {
    public let trackName: String?
    public let artistName: String?
    public let playerState: PlayerState

    public init(trackName: String?, artistName: String?, playerState: PlayerState) {
        self.trackName = trackName
        self.artistName = artistName
        self.playerState = playerState
    }
}
