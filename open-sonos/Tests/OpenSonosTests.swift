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

    @Test func computesAveragePlayerVolume() {
        let group = SonosGroupModel(
            id: "group-1",
            source: .local,
            householdID: nil,
            name: "Living Room",
            coordinatorID: "player-1",
            coordinatorBaseURL: nil,
            players: [
                SonosPlayerModel(id: "player-1", name: "Living Room", baseURL: nil, isCoordinator: true, webSocketURL: nil, capabilities: [], volume: 10, isMuted: false, volumeIsFixed: false),
                SonosPlayerModel(id: "player-2", name: "Kitchen", baseURL: nil, isCoordinator: false, webSocketURL: nil, capabilities: [], volume: 15, isMuted: false, volumeIsFixed: false),
                SonosPlayerModel(id: "player-3", name: "Office", baseURL: nil, isCoordinator: false, webSocketURL: nil, capabilities: [], volume: 20, isMuted: false, volumeIsFixed: false)
            ],
            playbackState: .paused,
            track: nil,
            volume: 0,
            isMuted: false,
            volumeIsFixed: false
        )

        #expect(group.averagePlayerVolume == 15)
    }
}
