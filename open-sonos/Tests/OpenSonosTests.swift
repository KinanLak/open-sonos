import Testing
@testable import OpenSonos

struct OpenSonosTests {
    @Test func mapsPlaybackStatesDefensively() {
        #expect(SonosPlaybackState(transportState: "PLAYING") == .playing)
        #expect(SonosPlaybackState(transportState: "PAUSED_PLAYBACK") == .paused)
        #expect(SonosPlaybackState(transportState: "garbage") == .unknown)
    }
}
