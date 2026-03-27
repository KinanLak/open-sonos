import Foundation

struct SonosCloudConfiguration: Hashable {
    var brokerBaseURL: URL

    var isValid: Bool {
        let scheme = brokerBaseURL.scheme?.lowercased()
        let host = brokerBaseURL.host?.lowercased()
        return scheme == "https" || ((host == "localhost" || host == "127.0.0.1") && scheme == "http")
    }
}

struct SonosCloudSession: Hashable, Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String?

    var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

struct SonosCloudHouseholdResource: Hashable {
    var id: String
    var name: String?
}

struct SonosCloudGroupsEnvelope: Decodable {
    var groups: [SonosCloudGroupResource]
    var players: [SonosCloudPlayerResource]
}

struct SonosCloudGroupResource: Decodable {
    var coordinatorId: String?
    var id: String
    var playbackState: String?
    var playerIds: [String]?
    var name: String?
}

struct SonosCloudPlayerResource: Decodable {
    var id: String
    var name: String?
    var webSocketUrl: String?
    var capabilities: [String]?
}

struct SonosCloudPlaybackStatusResource: Decodable {
    var playbackState: String?
}

struct SonosCloudGroupVolumeResource: Decodable {
    var muted: Bool?
    var fixed: Bool?
    var volume: Int?
}

struct SonosCloudMetadataStatusResource: Decodable {
    var container: SonosCloudContainerResource?
    var currentItem: SonosCloudItemResource?
    var streamInfo: String?
}

struct SonosCloudContainerResource: Decodable {
    var name: String?
    var type: String?
    var imageUrl: String?
}

struct SonosCloudItemResource: Decodable {
    var track: SonosCloudTrackResource?
}

struct SonosCloudTrackResource: Decodable {
    var name: String?
    var imageUrl: String?
    var artist: SonosCloudNamedResource?
    var album: SonosCloudAlbumResource?
}

struct SonosCloudNamedResource: Decodable {
    var name: String?
}

struct SonosCloudAlbumResource: Decodable {
    var name: String?
    var imageUrl: String?
}

struct SonosCloudTokenPayload: Decodable {
    var access_token: String
    var refresh_token: String
    var expires_in: TimeInterval
    var scope: String?
}

struct SonosBrokerTokenExchangeRequest: Encodable {
    var code: String
}

struct SonosBrokerTokenRefreshRequest: Encodable {
    var refresh_token: String
}

enum SonosCloudError: LocalizedError {
    case invalidConfiguration
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case missingAccessToken
    case missingBrokerURL
    case brokerUnavailable
    case unauthorized
    case badResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Provide a valid Sonos OAuth broker URL."
        case .invalidCallback:
            return "The callback URL is not valid for OpenSonos."
        case .stateMismatch:
            return "The Sonos login state did not match the pending sign-in request."
        case .missingAuthorizationCode:
            return "Sonos did not return an authorization code."
        case .missingAccessToken:
            return "No Sonos cloud session is available."
        case .missingBrokerURL:
            return "No Sonos OAuth broker URL is configured."
        case .brokerUnavailable:
            return "The Sonos OAuth broker is unavailable or misconfigured."
        case .unauthorized:
            return "Your Sonos cloud session expired or was rejected."
        case .badResponse:
            return "Unexpected response from the Sonos cloud API."
        case .httpStatus(let statusCode):
            return "The Sonos cloud API returned HTTP \(statusCode)."
        }
    }
}

extension SonosCloudMetadataStatusResource {
    var trackModel: SonosTrackModel? {
        if let track = currentItem?.track,
           let title = track.name?.nilIfBlank {
            return SonosTrackModel(
                title: title,
                artist: track.artist?.name?.nilIfBlank,
                album: track.album?.name?.nilIfBlank,
                albumArtURL: URL(string: track.imageUrl ?? track.album?.imageUrl ?? ""),
                containerName: container?.name?.nilIfBlank,
                streamInfo: streamInfo?.nilIfBlank
            )
        }

        if let containerName = container?.name?.nilIfBlank ?? streamInfo?.nilIfBlank {
            return SonosTrackModel(
                title: containerName,
                artist: nil,
                album: nil,
                albumArtURL: URL(string: container?.imageUrl ?? ""),
                containerName: container?.name?.nilIfBlank,
                streamInfo: streamInfo?.nilIfBlank
            )
        }

        return nil
    }
}
