import Testing
@testable import OpenSonos

struct OpenSonosTests {
    @Test func mapsPlaybackStatesDefensively() {
        #expect(SonosPlaybackState(transportState: "PLAYING") == .playing)
        #expect(SonosPlaybackState(transportState: "PLAYBACK_STATE_PLAYING") == .playing)
        #expect(SonosPlaybackState(transportState: "PAUSED_PLAYBACK") == .paused)
        #expect(SonosPlaybackState(transportState: "PLAYBACK_STATE_IDLE") == .stopped)
        #expect(SonosPlaybackState(transportState: "garbage") == .unknown)
    }

    @Test func buildsTrackFromCloudMetadataFallbacks() {
        let metadata = SonosCloudMetadataStatusResource(
            container: SonosCloudContainerResource(name: "BBC Radio 6", type: "station", imageUrl: nil),
            currentItem: nil,
            streamInfo: "Artist - Track"
        )

        #expect(metadata.trackModel?.title == "BBC Radio 6")
        #expect(metadata.trackModel?.subtitle == "BBC Radio 6")
    }
}
