import Foundation

enum SonosPlaybackState: String, Hashable {
    case playing
    case paused
    case stopped
    case transitioning
    case unknown

    init(transportState: String) {
        switch transportState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PLAYING":
            self = .playing
        case "PAUSED_PLAYBACK":
            self = .paused
        case "STOPPED":
            self = .stopped
        case "TRANSITIONING":
            self = .transitioning
        default:
            self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .playing:
            return "pause.fill"
        case .paused, .stopped, .transitioning, .unknown:
            return "play.fill"
        }
    }

    var statusLabel: String {
        switch self {
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .stopped:
            return "Stopped"
        case .transitioning:
            return "Loading"
        case .unknown:
            return "Unknown"
        }
    }
}

struct SonosTrackModel: Hashable {
    var title: String
    var artist: String?
    var album: String?
    var albumArtURL: URL?

    var subtitle: String {
        let components = [artist, album]
            .compactMap { $0?.nilIfBlank }
        return components.isEmpty ? "No metadata" : components.joined(separator: " - ")
    }
}

struct SonosPlayerModel: Identifiable, Hashable {
    var id: String
    var name: String
    var baseURL: URL
    var isCoordinator: Bool
}

struct SonosDeviceModel: Hashable {
    var uuid: String
    var roomName: String
    var friendlyName: String
    var modelName: String
    var locationURL: URL
    var baseURL: URL
}

struct SonosGroupModel: Identifiable, Hashable {
    var id: String
    var name: String
    var coordinatorID: String
    var coordinatorBaseURL: URL
    var players: [SonosPlayerModel]
    var playbackState: SonosPlaybackState
    var track: SonosTrackModel?
    var volume: Int
    var isMuted: Bool

    var isPlaying: Bool {
        playbackState == .playing
    }

    var playerSummary: String {
        if players.count <= 1 {
            return players.first?.name ?? name
        }

        return "\(players.count) rooms"
    }

    var nowPlayingSummary: String {
        guard let track else {
            return playbackState.statusLabel
        }

        let subtitle = track.subtitle.nilIfBlank
        return subtitle ?? playbackState.statusLabel
    }

    var menuBarLabel: String {
        String(name.prefix(12)).nilIfBlank ?? "Sonos"
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
