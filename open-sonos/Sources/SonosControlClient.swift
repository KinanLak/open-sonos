import Foundation

actor SonosControlClient {
    private let soapClient: SonosSOAPClient

    init(soapClient: SonosSOAPClient = SonosSOAPClient()) {
        self.soapClient = soapClient
    }

    func togglePlayback(for group: SonosGroupModel) async throws {
        switch group.playbackState {
        case .playing:
            try await pause(group)
        case .paused, .stopped, .transitioning, .unknown:
            try await play(group)
        }
    }

    func play(_ group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "Play",
            body: """
            <u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
              <Speed>1</Speed>
            </u:Play>
            """
        )
    }

    func pause(_ group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "Pause",
            body: """
            <u:Pause xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
            </u:Pause>
            """
        )
    }

    func nextTrack(_ group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "Next",
            body: """
            <u:Next xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
            </u:Next>
            """
        )
    }

    func previousTrack(_ group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "Previous",
            body: """
            <u:Previous xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
            </u:Previous>
            """
        )
    }

    func setGroupVolume(_ volume: Int, for group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        let clampedVolume = max(0, min(volume, 100))

        do {
            _ = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/GroupRenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:GroupRenderingControl:1",
                action: "SetGroupVolume",
                body: """
                <u:SetGroupVolume xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <DesiredVolume>\(clampedVolume)</DesiredVolume>
                </u:SetGroupVolume>
                """
            )
        } catch {
            _ = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/RenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
                action: "SetVolume",
                body: """
                <u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                  <DesiredVolume>\(clampedVolume)</DesiredVolume>
                </u:SetVolume>
                """
            )
        }
    }

    func setGroupMuted(_ isMuted: Bool, for group: SonosGroupModel) async throws {
        guard let baseURL = group.coordinatorBaseURL else { return }
        let muteValue = isMuted ? 1 : 0

        do {
            _ = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/GroupRenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:GroupRenderingControl:1",
                action: "SetGroupMute",
                body: """
                <u:SetGroupMute xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <DesiredMute>\(muteValue)</DesiredMute>
                </u:SetGroupMute>
                """
            )
        } catch {
            _ = try await soapClient.sendAction(
                baseURL: baseURL,
                path: "/MediaRenderer/RenderingControl/Control",
                serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
                action: "SetMute",
                body: """
                <u:SetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                  <DesiredMute>\(muteValue)</DesiredMute>
                </u:SetMute>
                """
            )
        }
    }

    func joinPlayer(_ player: SonosPlayerModel, to group: SonosGroupModel) async throws {
        guard let baseURL = player.baseURL else { return }

        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "SetAVTransportURI",
            body: """
            <u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
              <CurrentURI>x-rincon:\(group.coordinatorID)</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            </u:SetAVTransportURI>
            """
        )
    }

    func ungroupPlayer(_ player: SonosPlayerModel) async throws {
        guard let baseURL = player.baseURL else { return }

        _ = try await soapClient.sendAction(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: "BecomeCoordinatorOfStandaloneGroup",
            body: """
            <u:BecomeCoordinatorOfStandaloneGroup xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">
              <InstanceID>0</InstanceID>
            </u:BecomeCoordinatorOfStandaloneGroup>
            """
        )
    }
}
