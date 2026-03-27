import Foundation

enum SonosConnectionSource: String, CaseIterable, Identifiable, Hashable {
    case local
    case cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .cloud:
            return "Cloud"
        }
    }
}

enum SonosPlaybackState: String, Hashable {
    case playing
    case paused
    case stopped
    case transitioning
    case unknown

    init(transportState: String) {
        switch transportState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PLAYING", "PLAYBACK_STATE_PLAYING":
            self = .playing
        case "PAUSED_PLAYBACK", "PLAYBACK_STATE_PAUSED":
            self = .paused
        case "STOPPED", "PLAYBACK_STATE_IDLE":
            self = .stopped
        case "TRANSITIONING", "PLAYBACK_STATE_BUFFERING":
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
    var containerName: String?
    var streamInfo: String?

    var subtitle: String {
        let components = [artist, album]
            .compactMap { $0?.nilIfBlank }

        if !components.isEmpty {
            return components.joined(separator: " - ")
        }

        if let containerName = containerName?.nilIfBlank {
            return containerName
        }

        return streamInfo?.nilIfBlank ?? "No metadata"
    }
}

struct SonosPlayerModel: Identifiable, Hashable {
    var id: String
    var name: String
    var baseURL: URL?
    var isCoordinator: Bool
    var webSocketURL: URL?
    var capabilities: [String]
}

struct SonosDeviceModel: Hashable {
    var uuid: String
    var roomName: String
    var friendlyName: String
    var modelName: String
    var locationURL: URL
    var baseURL: URL
}

struct SonosHouseholdModel: Identifiable, Hashable {
    var id: String
    var source: SonosConnectionSource
    var name: String
    var samplePlayers: [String]

    var detailLabel: String {
        if !samplePlayers.isEmpty {
            return samplePlayers.joined(separator: ", ")
        }

        return id
    }
}

struct SonosGroupModel: Identifiable, Hashable {
    var id: String
    var source: SonosConnectionSource
    var householdID: String?
    var name: String
    var coordinatorID: String
    var coordinatorBaseURL: URL?
    var players: [SonosPlayerModel]
    var playbackState: SonosPlaybackState
    var track: SonosTrackModel?
    var volume: Int
    var isMuted: Bool
    var volumeIsFixed: Bool

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
