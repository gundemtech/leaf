import XCTest
@testable import LeafCore

final class MusicStateMachineTests: XCTestCase {
    func testFirstObservationEmits() {
        var sm = MusicStateMachine()
        let events = sm.observe(MusicTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "music_track_changed")
        XCTAssertEqual(events[0].payload["track"], "A")
        XCTAssertEqual(events[0].payload["artist"], "B")
        XCTAssertEqual(events[0].payload["player_state"], "playing")
    }

    func testIdempotentEmitsNothing() {
        var sm = MusicStateMachine()
        let obs = MusicTrackObservation(trackName: "A", artistName: "B", playerState: .playing)
        _ = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000).count, 0)
    }

    func testTrackChangeEmits() {
        var sm = MusicStateMachine()
        _ = sm.observe(MusicTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        let events = sm.observe(MusicTrackObservation(trackName: "C", artistName: "B", playerState: .playing), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["track"], "C")
    }

    func testPlayerStateFlipEmits() {
        var sm = MusicStateMachine()
        _ = sm.observe(MusicTrackObservation(trackName: "A", artistName: "B", playerState: .playing), nowMs: 1000)
        let events = sm.observe(MusicTrackObservation(trackName: "A", artistName: "B", playerState: .paused), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["player_state"], "paused")
    }
}
