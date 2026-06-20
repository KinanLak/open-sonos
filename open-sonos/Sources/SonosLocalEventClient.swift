import Foundation

/// How an AVTransport event affects the current track.
enum SonosLocalTrackChange: Sendable {
    case unchanged
    case updated(SonosTrackModel)
}

/// A real-time state change pushed by a Sonos speaker over UPnP GENA.
enum SonosLocalEvent: Sendable {
    case transport(coordinatorID: String, state: SonosPlaybackState?, track: SonosLocalTrackChange)
    case groupVolume(coordinatorID: String, volume: Int?, muted: Bool?)
    case topologyChanged
}

/// Subscribes to UPnP eventing on the coordinator of the active local group and
/// translates incoming `NOTIFY` callbacks into `SonosLocalEvent`s. Manages the
/// SUBSCRIBE / renew / UNSUBSCRIBE lifecycle and routes events by subscription ID.
actor SonosLocalEventClient {
    enum Service: CaseIterable {
        case avTransport
        case groupRendering
        case topology

        var eventPath: String {
            switch self {
            case .avTransport: return "/MediaRenderer/AVTransport/Event"
            case .groupRendering: return "/MediaRenderer/GroupRenderingControl/Event"
            case .topology: return "/ZoneGroupTopology/Event"
            }
        }
    }

    private struct Subscription {
        let service: Service
        let coordinatorID: String
        let baseURL: URL
        let sid: String
    }

    private let server = SonosEventServer()
    private let session: URLSession
    private var callbackURL: URL?
    private var subscriptions: [String: Subscription] = [:]
    private var currentTarget: (coordinatorID: String, baseURL: URL)?
    private var renewalTask: Task<Void, Never>?
    private var serverStarted = false

    private var onEvent: (@Sendable (SonosLocalEvent) async -> Void)?

    private static let subscriptionSeconds = 1800
    private static let renewalNanos: UInt64 = 1_500 * 1_000_000_000

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func setEventHandler(_ handler: @escaping @Sendable (SonosLocalEvent) async -> Void) {
        onEvent = handler
    }

    /// Points the subscriptions at a (possibly new) coordinator. No-ops when the
    /// target is unchanged and subscriptions are healthy.
    func setTarget(coordinatorID: String, baseURL: URL) async {
        if let currentTarget,
           currentTarget.coordinatorID == coordinatorID,
           currentTarget.baseURL == baseURL,
           !subscriptions.isEmpty {
            return
        }

        await teardown()
        currentTarget = (coordinatorID, baseURL)

        do {
            try await ensureServerStarted()
        } catch {
            currentTarget = nil
            return
        }

        for service in Service.allCases {
            if let sid = await subscribe(service: service, baseURL: baseURL) {
                subscriptions[sid] = Subscription(service: service, coordinatorID: coordinatorID, baseURL: baseURL, sid: sid)
            }
        }

        if !subscriptions.isEmpty {
            startRenewalLoop()
        }
    }

    func stop() async {
        await teardown()
        currentTarget = nil
        server.stop()
        serverStarted = false
    }

    // MARK: - Server

    private func ensureServerStarted() async throws {
        guard !serverStarted else { return }

        let port = try await server.start()
        guard let ip = LocalNetworkInterface.primaryIPv4Address() else {
            throw SonosEventServerError.noLocalAddress
        }

        callbackURL = URL(string: "http://\(ip):\(port)/notify")
        server.onNotify = { [weak self] sid, body in
            guard let self else { return }
            Task { await self.handleNotify(sid: sid, body: body) }
        }
        serverStarted = true
    }

    // MARK: - Subscription lifecycle

    private func subscribe(service: Service, baseURL: URL) async -> String? {
        guard
            let callbackURL,
            let url = URL(string: service.eventPath, relativeTo: baseURL)?.absoluteURL
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL.absoluteString)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-\(Self.subscriptionSeconds)", forHTTPHeaderField: "TIMEOUT")

        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode),
            let sid = http.value(forHTTPHeaderField: "SID")?.nilIfBlank
        else {
            return nil
        }

        return sid
    }

    private func renew(_ subscription: Subscription) async -> Bool {
        guard let url = URL(string: subscription.service.eventPath, relativeTo: subscription.baseURL)?.absoluteURL else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(subscription.sid, forHTTPHeaderField: "SID")
        request.setValue("Second-\(Self.subscriptionSeconds)", forHTTPHeaderField: "TIMEOUT")

        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode)
        else {
            return false
        }

        return true
    }

    private func startRenewalLoop() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.renewalNanos)
                guard let self, !Task.isCancelled else { return }
                await self.renewAll()
            }
        }
    }

    private func renewAll() async {
        guard let target = currentTarget else { return }

        var refreshed: [String: Subscription] = [:]
        for subscription in subscriptions.values {
            if await renew(subscription) {
                refreshed[subscription.sid] = subscription
            } else if let sid = await subscribe(service: subscription.service, baseURL: target.baseURL) {
                refreshed[sid] = Subscription(service: subscription.service, coordinatorID: target.coordinatorID, baseURL: target.baseURL, sid: sid)
            }
        }
        subscriptions = refreshed
    }

    private func teardown() async {
        renewalTask?.cancel()
        renewalTask = nil

        let active = Array(subscriptions.values)
        subscriptions.removeAll()

        for subscription in active {
            guard let url = URL(string: subscription.service.eventPath, relativeTo: subscription.baseURL)?.absoluteURL else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "UNSUBSCRIBE"
            request.setValue(subscription.sid, forHTTPHeaderField: "SID")
            _ = try? await session.data(for: request)
        }
    }

    // MARK: - Notification routing

    private func handleNotify(sid: String, body: String) async {
        guard let subscription = subscriptions[sid], let onEvent else { return }
        guard let event = Self.parse(service: subscription.service, coordinatorID: subscription.coordinatorID, baseURL: subscription.baseURL, body: body) else { return }
        await onEvent(event)
    }

    private static func parse(service: Service, coordinatorID: String, baseURL: URL, body: String) -> SonosLocalEvent? {
        switch service {
        case .topology:
            return .topologyChanged

        case .avTransport:
            guard let lastChange = SonosXML.firstValue(for: "LastChange", in: body) else { return nil }

            let state = SonosXML.firstAttributeValue(for: "TransportState", in: lastChange)
                .map { SonosPlaybackState(transportState: $0) }

            var track: SonosLocalTrackChange = .unchanged
            if let metadata = SonosXML.firstAttributeValue(for: "CurrentTrackMetaData", in: lastChange),
               let parsed = SonosParsing.parseTrackMetadata(xml: metadata, baseURL: baseURL) {
                track = .updated(parsed)
            }

            if state == nil, case .unchanged = track { return nil }
            return .transport(coordinatorID: coordinatorID, state: state, track: track)

        case .groupRendering:
            guard let lastChange = SonosXML.firstValue(for: "LastChange", in: body) else { return nil }

            let volume = SonosXML.firstAttributeValue(for: "GroupVolume", in: lastChange).flatMap { Int($0) }
            let muted = SonosXML.firstAttributeValue(for: "GroupMute", in: lastChange).map { $0 == "1" }

            if volume == nil, muted == nil { return nil }
            return .groupVolume(coordinatorID: coordinatorID, volume: volume, muted: muted)
        }
    }
}
