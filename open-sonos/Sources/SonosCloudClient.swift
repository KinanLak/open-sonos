import Foundation

actor SonosCloudClient {
    private let session: URLSession
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    func authorizationURL(configuration: SonosCloudConfiguration, state: String) throws -> URL {
        guard configuration.isValid else {
            throw SonosCloudError.invalidConfiguration
        }

        guard var components = URLComponents(url: configuration.brokerBaseURL, resolvingAgainstBaseURL: false) else {
            throw SonosCloudError.invalidConfiguration
        }

        components.path = normalizedPath(components.path, appending: "/api/sonos/authorize")
        components.queryItems = [URLQueryItem(name: "state", value: state)]

        guard let authorizationURL = components.url else {
            throw SonosCloudError.invalidConfiguration
        }

        return authorizationURL
    }

    func exchangeCode(_ code: String, configuration: SonosCloudConfiguration) async throws -> SonosCloudSession {
        let payload = try await brokerRequest(
            path: "/api/sonos/exchange",
            configuration: configuration,
            body: SonosBrokerTokenExchangeRequest(code: code)
        )

        return SonosCloudSession(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            expiresAt: Date().addingTimeInterval(payload.expires_in),
            scope: payload.scope
        )
    }

    func refreshSession(_ currentSession: SonosCloudSession, configuration: SonosCloudConfiguration) async throws -> SonosCloudSession {
        let payload = try await brokerRequest(
            path: "/api/sonos/refresh",
            configuration: configuration,
            body: SonosBrokerTokenRefreshRequest(refresh_token: currentSession.refreshToken)
        )

        return SonosCloudSession(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            expiresAt: Date().addingTimeInterval(payload.expires_in),
            scope: payload.scope
        )
    }

    func getHouseholds(accessToken: String) async throws -> [SonosCloudHouseholdResource] {
        let data = try await sendRequest(path: "/households", method: "GET", accessToken: accessToken)

        if let resources = try? jsonDecoder.decode([RawHousehold].self, from: data) {
            return resources.map { SonosCloudHouseholdResource(id: $0.id ?? UUID().uuidString, name: $0.name) }
        }

        if let object = try? jsonDecoder.decode(RawHouseholdEnvelope.self, from: data) {
            return object.households.map { SonosCloudHouseholdResource(id: $0.id ?? UUID().uuidString, name: $0.name) }
        }

        throw SonosCloudError.badResponse
    }

    func getGroups(householdID: String, accessToken: String) async throws -> SonosCloudGroupsEnvelope {
        let data = try await sendRequest(path: "/households/\(householdID)/groups", method: "GET", accessToken: accessToken)
        return try jsonDecoder.decode(SonosCloudGroupsEnvelope.self, from: data)
    }

    func getPlayback(groupID: String, accessToken: String) async throws -> SonosCloudPlaybackStatusResource {
        let data = try await sendRequest(path: "/groups/\(groupID)/playback", method: "GET", accessToken: accessToken)
        return try jsonDecoder.decode(SonosCloudPlaybackStatusResource.self, from: data)
    }

    func getMetadata(groupID: String, accessToken: String) async throws -> SonosCloudMetadataStatusResource {
        let data = try await sendRequest(path: "/groups/\(groupID)/playbackMetadata", method: "GET", accessToken: accessToken)
        return try jsonDecoder.decode(SonosCloudMetadataStatusResource.self, from: data)
    }

    func getGroupVolume(groupID: String, accessToken: String) async throws -> SonosCloudGroupVolumeResource {
        let data = try await sendRequest(path: "/groups/\(groupID)/groupVolume", method: "GET", accessToken: accessToken)
        return try jsonDecoder.decode(SonosCloudGroupVolumeResource.self, from: data)
    }

    func play(groupID: String, accessToken: String) async throws {
        _ = try await sendRequest(path: "/groups/\(groupID)/playback/play", method: "POST", accessToken: accessToken)
    }

    func pause(groupID: String, accessToken: String) async throws {
        _ = try await sendRequest(path: "/groups/\(groupID)/playback/pause", method: "POST", accessToken: accessToken)
    }

    func next(groupID: String, accessToken: String) async throws {
        _ = try await sendRequest(path: "/groups/\(groupID)/playback/skipToNextTrack", method: "POST", accessToken: accessToken)
    }

    func previous(groupID: String, accessToken: String) async throws {
        _ = try await sendRequest(path: "/groups/\(groupID)/playback/skipToPreviousTrack", method: "POST", accessToken: accessToken)
    }

    func setGroupVolume(groupID: String, volume: Int, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["volume": max(0, min(volume, 100))])
        _ = try await sendRequest(path: "/groups/\(groupID)/groupVolume", method: "POST", accessToken: accessToken, body: body)
    }

    func setGroupMuted(groupID: String, muted: Bool, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["muted": muted])
        _ = try await sendRequest(path: "/groups/\(groupID)/groupVolume/mute", method: "POST", accessToken: accessToken, body: body)
    }

    func brokerHealth(configuration: SonosCloudConfiguration) async throws -> String {
        guard configuration.isValid else {
            throw SonosCloudError.invalidConfiguration
        }

        let data = try await sendBrokerRequest(path: "/api/sonos/health", method: "GET", configuration: configuration)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return object["status"] as? String ?? "ok"
    }

    private func brokerRequest<RequestBody: Encodable>(path: String, configuration: SonosCloudConfiguration, body: RequestBody) async throws -> SonosCloudTokenPayload {
        let encodedBody = try jsonEncoder.encode(body)
        let data = try await sendBrokerRequest(path: path, method: "POST", configuration: configuration, body: encodedBody)
        return try jsonDecoder.decode(SonosCloudTokenPayload.self, from: data)
    }

    private func sendBrokerRequest(path: String, method: String, configuration: SonosCloudConfiguration, body: Data? = nil) async throws -> Data {
        guard let requestURL = brokerURL(for: path, configuration: configuration) else {
            throw SonosCloudError.invalidConfiguration
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return data
    }

    private func sendRequest(path: String, method: String, accessToken: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.ws.sonos.com/control/api/v1\(path)") else {
            throw SonosCloudError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return data
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonosCloudError.badResponse
        }

        if httpResponse.statusCode == 401 {
            throw SonosCloudError.unauthorized
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SonosCloudError.httpStatus(httpResponse.statusCode)
        }
    }

    private func brokerURL(for path: String, configuration: SonosCloudConfiguration) -> URL? {
        guard var components = URLComponents(url: configuration.brokerBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = normalizedPath(components.path, appending: path)
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func normalizedPath(_ basePath: String, appending path: String) -> String {
        let trimmedBase = basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = [trimmedBase, trimmedPath].filter { !$0.isEmpty }
        return "/" + parts.joined(separator: "/")
    }
}

private struct RawHouseholdEnvelope: Decodable {
    var households: [RawHousehold]
}

private struct RawHousehold: Decodable {
    var id: String?
    var name: String?
}
