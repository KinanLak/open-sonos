import Foundation

/// A real-time state change for a cloud group, relayed from Sonos webhooks via the broker.
enum SonosCloudEvent: Sendable {
    case playback(groupID: String, state: SonosPlaybackState)
    case metadata(groupID: String, track: SonosTrackModel?)
    case groupVolume(groupID: String, volume: Int?, muted: Bool?)
    case groupsChanged(householdID: String)
}

/// Maintains a WebSocket to the OAuth broker's relay endpoint. The broker runs a
/// per-household Durable Object that subscribes to Sonos events on our behalf and
/// forwards them here. Handles (re)configuration, reconnection, and parsing.
actor SonosCloudRelayClient {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?

    private var target: (brokerBaseURL: URL, householdID: String)?
    private var pendingGroupIDs: [String] = []
    private var pendingAccessToken = ""
    private var didConfigure = false
    private var reconnectAttempts = 0

    private var onEvent: (@Sendable (SonosCloudEvent) async -> Void)?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func setEventHandler(_ handler: @escaping @Sendable (SonosCloudEvent) async -> Void) {
        onEvent = handler
    }

    /// Connects to the relay for a household (or reconfigures if already connected).
    func connect(brokerBaseURL: URL, householdID: String, groupIDs: [String], accessToken: String) async {
        if let target, target.brokerBaseURL == brokerBaseURL, target.householdID == householdID, task != nil {
            await sendConfigure(groupIDs: groupIDs, accessToken: accessToken)
            return
        }

        await disconnect()
        target = (brokerBaseURL, householdID)
        reconnectAttempts = 0
        openSocket(groupIDs: groupIDs, accessToken: accessToken)
    }

    func disconnect() async {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        target = nil
    }

    // MARK: - Socket lifecycle

    private func openSocket(groupIDs: [String], accessToken: String) {
        guard let target, let url = Self.relayURL(brokerBaseURL: target.brokerBaseURL, householdID: target.householdID) else { return }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // New socket — the Durable Object has no config yet, so always (re)send it.
        didConfigure = false
        Task { await self.sendConfigure(groupIDs: groupIDs, accessToken: accessToken) }

        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled, let task {
            do {
                let message = try await task.receive()
                await dispatch(message)
                reconnectAttempts = 0
            } catch {
                handleDisconnect()
                return
            }
        }
    }

    private func handleDisconnect() {
        task = nil
        guard target != nil else { return } // intentional disconnect clears target

        let attempt = min(reconnectAttempts, 5)
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(attempt)))

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.reconnect()
        }
    }

    private func reconnect() {
        guard target != nil, task == nil else { return }
        openSocket(groupIDs: pendingGroupIDs, accessToken: pendingAccessToken)
    }

    // MARK: - Sending

    private func sendConfigure(groupIDs: [String], accessToken: String) async {
        guard let target else { return }

        // Skip redundant reconfigures (e.g. the 30s refresh) — they would make the
        // broker re-subscribe needlessly. Always send on a fresh socket.
        if didConfigure, groupIDs == pendingGroupIDs, accessToken == pendingAccessToken {
            return
        }

        pendingGroupIDs = groupIDs
        pendingAccessToken = accessToken
        didConfigure = true
        await send([
            "type": "configure",
            "householdId": target.householdID,
            "groupIds": groupIDs,
            "accessToken": accessToken,
        ])
    }

    private func send(_ object: [String: Any]) async {
        guard
            let task,
            let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return
        }
        try? await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Receiving

    private func dispatch(_ message: URLSessionWebSocketTask.Message) async {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let value):
            text = String(decoding: value, as: UTF8.self)
        @unknown default:
            return
        }

        guard
            let onEvent,
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "event"
        else {
            return
        }

        let namespace = object["namespace"] as? String ?? ""
        let groupID = object["targetValue"] as? String ?? ""
        let bodyData = (object["body"] as? String ?? "").data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()

        switch namespace {
        case "playback":
            if let parsed = try? decoder.decode(SonosCloudPlaybackStatusResource.self, from: bodyData),
               let state = parsed.playbackState {
                await onEvent(.playback(groupID: groupID, state: SonosPlaybackState(transportState: state)))
            }
        case "playbackMetadata":
            if let parsed = try? decoder.decode(SonosCloudMetadataStatusResource.self, from: bodyData) {
                await onEvent(.metadata(groupID: groupID, track: parsed.trackModel))
            }
        case "groupVolume":
            if let parsed = try? decoder.decode(SonosCloudGroupVolumeResource.self, from: bodyData) {
                await onEvent(.groupVolume(groupID: groupID, volume: parsed.volume, muted: parsed.muted))
            }
        case "groups":
            await onEvent(.groupsChanged(householdID: object["householdId"] as? String ?? ""))
        default:
            break
        }
    }

    private static func relayURL(brokerBaseURL: URL, householdID: String) -> URL? {
        guard var components = URLComponents(url: brokerBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let basePath = components.path == "/" ? "" : components.path
        components.path = basePath + "/api/sonos/relay"
        components.queryItems = [URLQueryItem(name: "householdId", value: householdID)]
        return components.url
    }
}
