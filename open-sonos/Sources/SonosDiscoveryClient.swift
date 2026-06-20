import Darwin
import Foundation

enum SonosDiscoveryError: LocalizedError {
    case socketSetupFailed
    case discoveryReturnedNoResults
    case topologyUnavailable

    var errorDescription: String? {
        switch self {
        case .socketSetupFailed:
            return "Unable to create the local discovery socket."
        case .discoveryReturnedNoResults:
            return "No Sonos speakers responded on the local network."
        case .topologyUnavailable:
            return "Speakers were found, but the Sonos topology could not be loaded."
        }
    }
}

actor SonosDiscoveryClient {
    private let soapClient: SonosSOAPClient

    init(soapClient: SonosSOAPClient = SonosSOAPClient()) {
        self.soapClient = soapClient
    }

    func discoverGroups() async throws -> [SonosGroupModel] {
        let locations = try discoverLocations(timeout: 1.25)
        guard !locations.isEmpty else {
            throw SonosDiscoveryError.discoveryReturnedNoResults
        }

        let devices = await fetchDevices(from: locations)
        guard !devices.isEmpty else {
            throw SonosDiscoveryError.discoveryReturnedNoResults
        }

        let topologyGroups = await fetchTopologyGroups(using: devices)
        if topologyGroups.isEmpty {
            let standaloneGroups = await buildStandaloneGroups(from: devices)
            return standaloneGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uuid, $0) })
        var groups: [SonosGroupModel] = []

        for topologyGroup in topologyGroups {
            if let group = await buildGroup(from: topologyGroup, devicesByID: devicesByID) {
                groups.append(group)
            }
        }

        if groups.isEmpty {
            throw SonosDiscoveryError.topologyUnavailable
        }

        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func discoverLocations(timeout: TimeInterval) throws -> [URL] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw SonosDiscoveryError.socketSetupFailed
        }

        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var timeoutValue = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        var multicastAddress = in_addr()
        inet_pton(AF_INET, "239.255.255.250", &multicastAddress)

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr = multicastAddress

        let payload = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: \"ssdp:discover\"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r
        """

        let sendResult = payload.withCString { pointer in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(socketFD, pointer, strlen(pointer), 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sendResult >= 0 else {
            throw SonosDiscoveryError.socketSetupFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        var locations = Set<URL>()

        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let received = buffer.withUnsafeMutableBytes { rawBuffer in
                recvfrom(socketFD, rawBuffer.baseAddress, rawBuffer.count, 0, nil, nil)
            }

            if received > 0 {
                let response = String(decoding: buffer.prefix(Int(received)), as: UTF8.self)
                if let location = locationURL(from: response) {
                    locations.insert(location)
                }
                continue
            }

            if received == -1 {
                let currentErrno = errno
                if currentErrno == EAGAIN || currentErrno == EWOULDBLOCK {
                    continue
                }
                break
            }

            break
        }

        return Array(locations)
    }

    private func locationURL(from response: String) -> URL? {
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let header = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard header == "location" else { continue }
            return URL(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private func fetchDevices(from locations: [URL]) async -> [SonosDeviceModel] {
        var devicesByID: [String: SonosDeviceModel] = [:]

        for location in locations {
            do {
                let xml = try await soapClient.fetchText(from: location)
                guard let device = SonosParsing.parseDeviceDescription(data: Data(xml.utf8), locationURL: location) else {
                    continue
                }
                devicesByID[device.uuid] = device
            } catch {
                continue
            }
        }

        return Array(devicesByID.values)
    }

    private func fetchTopologyGroups(using devices: [SonosDeviceModel]) async -> [SonosTopologyGroup] {
        for device in devices {
            do {
                let xml = try await zoneGroupState(baseURL: device.baseURL)
                let groups = SonosParsing.parseZoneGroupState(xml: xml)
                if !groups.isEmpty {
                    return groups
                }
            } catch {
                continue
            }
        }

        return []
    }

    private func buildGroup(from topologyGroup: SonosTopologyGroup, devicesByID: [String: SonosDeviceModel]) async -> SonosGroupModel? {
        guard let coordinator = topologyGroup.members.first(where: { $0.uuid == topologyGroup.coordinatorID }) ?? topologyGroup.members.first else {
            return nil
        }

        guard let coordinatorBaseURL = coordinator.baseURL ?? devicesByID[coordinator.uuid]?.baseURL else {
            return nil
        }

        var players: [SonosPlayerModel] = []

        for member in topologyGroup.members {
            guard let baseURL = member.baseURL ?? devicesByID[member.uuid]?.baseURL ?? Optional(coordinatorBaseURL) else {
                continue
            }

            let resolvedName = member.name.nilIfBlank ?? devicesByID[member.uuid]?.roomName ?? devicesByID[member.uuid]?.friendlyName ?? "Sonos"
            let volume = await loadIndividualVolume(baseURL: baseURL)
            let isMuted = await loadIndividualMuted(baseURL: baseURL)
            players.append(SonosPlayerModel(
                id: member.uuid,
                name: resolvedName,
                baseURL: baseURL,
                isCoordinator: member.uuid == topologyGroup.coordinatorID,
                webSocketURL: nil,
                capabilities: [],
                volume: volume,
                isMuted: isMuted,
                volumeIsFixed: false
            ))
        }

        guard !players.isEmpty else {
            return nil
        }

        let playbackState = await loadPlaybackState(baseURL: coordinatorBaseURL)
        let track = await loadTrack(baseURL: coordinatorBaseURL)
        let volume = await loadVolume(baseURL: coordinatorBaseURL)
        let isMuted = await loadMuted(baseURL: coordinatorBaseURL)
        let coordinatorName = players.first(where: { $0.isCoordinator })?.name ?? players.first?.name ?? "Sonos"

        return SonosGroupModel(
            id: topologyGroup.id,
            source: .local,
            householdID: nil,
            name: coordinatorName,
            coordinatorID: topologyGroup.coordinatorID,
            coordinatorBaseURL: coordinatorBaseURL,
            players: players,
            playbackState: playbackState,
            track: track,
            volume: volume,
            isMuted: isMuted,
            volumeIsFixed: false
        )
    }

    private func buildStandaloneGroups(from devices: [SonosDeviceModel]) async -> [SonosGroupModel] {
        var groups: [SonosGroupModel] = []

        for device in devices {
            let playbackState = await loadPlaybackState(baseURL: device.baseURL)
            let track = await loadTrack(baseURL: device.baseURL)
            let volume = await loadIndividualVolume(baseURL: device.baseURL)
            let isMuted = await loadIndividualMuted(baseURL: device.baseURL)

            groups.append(
                SonosGroupModel(
                    id: device.uuid,
                    source: .local,
                    householdID: nil,
                    name: device.roomName,
                    coordinatorID: device.uuid,
                    coordinatorBaseURL: device.baseURL,
                    players: [SonosPlayerModel(id: device.uuid, name: device.roomName, baseURL: device.baseURL, isCoordinator: true, webSocketURL: nil, capabilities: [], volume: volume, isMuted: isMuted, volumeIsFixed: false)],
                    playbackState: playbackState,
                    track: track,
                    volume: volume,
                    isMuted: isMuted,
                    volumeIsFixed: false
                )
            )
        }

        return groups
    }

    private func zoneGroupState(baseURL: URL) async throws -> String {
        let response = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/ZoneGroupTopology/Control",
            serviceType: "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
            action: "GetZoneGroupState",
            body: "<u:GetZoneGroupState xmlns:u=\"urn:schemas-upnp-org:service:ZoneGroupTopology:1\"></u:GetZoneGroupState>"
        )

        return SonosXML.firstValue(for: "ZoneGroupState", in: response) ?? ""
    }

    private func loadPlaybackState(baseURL: URL) async -> SonosPlaybackState {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/AVTransport/Control",
                serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
                action: "GetTransportInfo",
                body: """
                <u:GetTransportInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
                  <InstanceID>0</InstanceID>
                </u:GetTransportInfo>
                """
            )

            return SonosPlaybackState(transportState: SonosXML.firstValue(for: "CurrentTransportState", in: response) ?? "")
        } catch {
            return .unknown
        }
    }

    private func loadTrack(baseURL: URL) async -> SonosTrackModel? {
        var track = await loadTrackFromPositionInfo(baseURL: baseURL)
        if track == nil {
            track = await loadTrackFromMediaInfo(baseURL: baseURL)
        }

        guard var track else { return nil }

        if track.albumArtURL == nil {
            track.albumArtURL = await ArtworkFallbackClient.shared.artworkURL(
                artist: track.artist,
                album: track.album,
                title: track.title
            )
        }

        return track
    }

    private func loadTrackFromPositionInfo(baseURL: URL) async -> SonosTrackModel? {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/AVTransport/Control",
                serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
                action: "GetPositionInfo",
                body: """
                <u:GetPositionInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
                  <InstanceID>0</InstanceID>
                </u:GetPositionInfo>
                """
            )

            let metadata = SonosXML.firstValue(for: "TrackMetaData", in: response) ?? ""
            let rawTrackURI = SonosXML.firstValue(for: "TrackURI", in: response)?.nilIfBlank

            if var track = SonosParsing.parseTrackMetadata(xml: metadata, baseURL: baseURL) {
                track.trackURI = rawTrackURI
                return track
            }

            if let trackURI = rawTrackURI {
                let fallbackTitle = URL(string: trackURI)?.lastPathComponent.removingPercentEncoding?.nilIfBlank
                if let fallbackTitle {
                    return SonosTrackModel(
                        title: fallbackTitle,
                        artist: nil,
                        album: nil,
                        albumArtURL: nil,
                        containerName: nil,
                        streamInfo: nil,
                        trackURI: trackURI
                    )
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    private func loadTrackFromMediaInfo(baseURL: URL) async -> SonosTrackModel? {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/AVTransport/Control",
                serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
                action: "GetMediaInfo",
                body: """
                <u:GetMediaInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
                  <InstanceID>0</InstanceID>
                </u:GetMediaInfo>
                """
            )

            let metadata = SonosXML.firstValue(for: "CurrentURIMetaData", in: response) ?? ""
            if let track = SonosParsing.parseTrackMetadata(xml: metadata, baseURL: baseURL) {
                return track
            }

            if let currentURI = SonosXML.firstValue(for: "CurrentURI", in: response)?.nilIfBlank {
                let fallbackTitle = URL(string: currentURI)?.lastPathComponent.removingPercentEncoding?.nilIfBlank ?? currentURI
                return SonosTrackModel(
                    title: fallbackTitle,
                    artist: nil,
                    album: nil,
                    albumArtURL: nil,
                    containerName: nil,
                    streamInfo: nil
                )
            }

            return nil
        } catch {
            return nil
        }
    }

    private func loadVolume(baseURL: URL) async -> Int {
        if let groupVolume = await loadGroupVolume(baseURL: baseURL) {
            return groupVolume
        }
        return await loadIndividualVolume(baseURL: baseURL)
    }

    private func loadMuted(baseURL: URL) async -> Bool {
        if let groupMuted = await loadGroupMuted(baseURL: baseURL) {
            return groupMuted
        }
        return await loadIndividualMuted(baseURL: baseURL)
    }

    private func loadGroupVolume(baseURL: URL) async -> Int? {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/GroupRenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:GroupRenderingControl:1",
                action: "GetGroupVolume",
                body: """
                <u:GetGroupVolume xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">
                  <InstanceID>0</InstanceID>
                </u:GetGroupVolume>
                """
            )

            return Int(SonosXML.firstValue(for: "CurrentVolume", in: response) ?? "")
        } catch {
            return nil
        }
    }

    private func loadGroupMuted(baseURL: URL) async -> Bool? {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/GroupRenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:GroupRenderingControl:1",
                action: "GetGroupMute",
                body: """
                <u:GetGroupMute xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">
                  <InstanceID>0</InstanceID>
                </u:GetGroupMute>
                """
            )

            return (SonosXML.firstValue(for: "CurrentMute", in: response) ?? "0") == "1"
        } catch {
            return nil
        }
    }

    private func loadIndividualVolume(baseURL: URL) async -> Int {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/RenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
                action: "GetVolume",
                body: """
                <u:GetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                </u:GetVolume>
                """
            )

            return Int(SonosXML.firstValue(for: "CurrentVolume", in: response) ?? "") ?? 0
        } catch {
            return 0
        }
    }

    private func loadIndividualMuted(baseURL: URL) async -> Bool {
        do {
            let response = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/RenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
                action: "GetMute",
                body: """
                <u:GetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                </u:GetMute>
                """
            )

            return (SonosXML.firstValue(for: "CurrentMute", in: response) ?? "0") == "1"
        } catch {
            return false
        }
    }
}
