import XCTest
@testable import LeafCore

final class SpotifyStateMachineTests: XCTestCase {
    func testFirstObservationEmits() {
        var sm = SpotifyStateMachine()
        let events = sm.observe(SpotifyTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "spotify_track_changed")
    }

    func testIdempotentEmitsNothing() {
        var sm = SpotifyStateMachine()
        let obs = SpotifyTrackObservation(trackName: "A", artistName: "B", playerState: .playing)
        _ = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000).count, 0)
    }

    func testTrackChangeEmits() {
        var sm = SpotifyStateMachine()
        _ = sm.observe(SpotifyTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        let events = sm.observe(SpotifyTrackObservation(trackName: "Z", artistName: "B", playerState: .playing), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["track"], "Z")
    }

    func testStoppedStateEmits() {
        var sm = SpotifyStateMachine()
        _ = sm.observe(SpotifyTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        let events = sm.observe(SpotifyTrackObservation(trackName: "A", artistName: "B", playerState: .stopped), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["player_state"], "stopped")
    }
}
