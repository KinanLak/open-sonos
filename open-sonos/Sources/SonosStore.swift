import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SonosStore {
    var localGroups: [SonosGroupModel] = []
    var cloudGroups: [SonosGroupModel] = []
    var cloudHouseholds: [SonosHouseholdModel] = []

    var selectedLocalGroupID: String?
    var selectedCloudGroupID: String?
    var selectedCloudHouseholdID: String?
    var preferredSource: SonosConnectionSource = .local {
        didSet {
            userDefaults.set(preferredSource.rawValue, forKey: DefaultsKeys.preferredSource)
            updateStatusFromActiveSource()
        }
    }

    var isRefreshing = false
    var isPerformingAction = false
    var isCloudAuthenticating = false
    var isSpotifyRefreshing = false
    var errorMessage: String?
    var statusMessage = "Ready to scan your Sonos system"
    var cloudStatusMessage = "Cloud not configured"
    var spotifyStatusMessage = "Spotify disabled"
    var lastUpdatedAt: Date?

    var cloudBrokerURLDraft: String {
        didSet {
            userDefaults.set(cloudBrokerURLDraft, forKey: DefaultsKeys.cloudBrokerURL)
            cloudStatusMessage = isCloudConfigured ? "Cloud configured" : initialCloudStatusMessage
        }
    }
    var isSpotifyTransferEnabled: Bool = false {
        didSet {
            userDefaults.set(isSpotifyTransferEnabled, forKey: DefaultsKeys.spotifyTransferEnabled)
            if isSpotifyTransferEnabled {
                Task { await refreshSpotifyDesktopState() }
            } else {
                spotifyDesktopDevices = []
                spotifyDesktopActiveDeviceID = nil
                spotifyStatusMessage = "Spotify disabled"
            }
        }
    }
    var spotifyDesktopStatus = SpotifyDesktopStatus(helperInstalled: false, appRunning: false, isLoggedIn: false)
    var spotifyDesktopDevices: [SpotifyDesktopDevice] = []
    var spotifyDesktopActiveDeviceID: String?

    // BPM sync
    var currentBPM: Double?
    var isBPMSyncEnabled: Bool = false {
        didSet {
            userDefaults.set(isBPMSyncEnabled, forKey: DefaultsKeys.bpmEnabled)
            if isBPMSyncEnabled {
                lastBPMTrackKey = nil
                refreshBPMIfNeeded()
            } else {
                currentBPM = nil
                lastBPMTrackKey = nil
                bpmStatusMessage = ""
            }
        }
    }
    var bpmStatusMessage = ""

    // Waveform animation
    var waveformFPS: Double = 10 {
        didSet { userDefaults.set(waveformFPS, forKey: DefaultsKeys.waveformFPS) }
    }

    @ObservationIgnored private let discoveryClient: SonosDiscoveryClient
    @ObservationIgnored private let controlClient: SonosControlClient
    @ObservationIgnored private let cloudClient: SonosCloudClient
    @ObservationIgnored private let spotifyDesktopClient: SpotifyDesktopClient
    @ObservationIgnored private let bpmClient = BPMClient()
    @ObservationIgnored private let localEventClient = SonosLocalEventClient()
    @ObservationIgnored private let cloudRelayClient = SonosCloudRelayClient()
    @ObservationIgnored private var topologyRefreshTask: Task<Void, Never>?
    // Bumped on every optimistic UI mutation. A full refresh that was already in
    // flight when the user acted must not overwrite the optimistic state with a
    // pre-action (stale) snapshot — it checks this epoch before applying.
    @ObservationIgnored private var actionEpoch = 0
    // After the user toggles play/pause, the speaker may take time to actually
    // start (buffering), reporting transient non-target states meanwhile. We hold
    // the intended state against those contradicting events until it's confirmed
    // or this lock expires.
    @ObservationIgnored private var pendingPlaybackIntent: PlaybackIntent?
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let keychain: SonosKeychainStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var playerVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var pendingOAuthState: String?
    @ObservationIgnored private var cloudSession: SonosCloudSession?
    @ObservationIgnored private var lastBPMTrackKey: String?
    @ObservationIgnored private var lastUsedSonosPlayerNames: [String]

    init(
        discoveryClient: SonosDiscoveryClient = SonosDiscoveryClient(),
        controlClient: SonosControlClient = SonosControlClient(),
        cloudClient: SonosCloudClient = SonosCloudClient(),
        spotifyDesktopClient: SpotifyDesktopClient = SpotifyDesktopClient(),
        userDefaults: UserDefaults = .standard,
        keychain: SonosKeychainStore = SonosKeychainStore()
    ) {
        self.discoveryClient = discoveryClient
        self.controlClient = controlClient
        self.cloudClient = cloudClient
        self.spotifyDesktopClient = spotifyDesktopClient
        self.userDefaults = userDefaults
        self.keychain = keychain

        self.cloudBrokerURLDraft = userDefaults.string(forKey: DefaultsKeys.cloudBrokerURL) ?? DefaultsKeys.defaultCloudBrokerURL
        self.selectedLocalGroupID = userDefaults.string(forKey: DefaultsKeys.selectedLocalGroupID)
        self.selectedCloudGroupID = userDefaults.string(forKey: DefaultsKeys.selectedCloudGroupID)
        self.selectedCloudHouseholdID = userDefaults.string(forKey: DefaultsKeys.selectedCloudHouseholdID)
        self.preferredSource = SonosConnectionSource(rawValue: userDefaults.string(forKey: DefaultsKeys.preferredSource) ?? "local") ?? .local
        self.cloudSession = Self.loadCloudSession(from: keychain)
        self.lastUsedSonosPlayerNames = userDefaults.stringArray(forKey: DefaultsKeys.lastUsedSonosPlayerNames) ?? []
        self.cloudStatusMessage = initialCloudStatusMessage
        self.isSpotifyTransferEnabled = userDefaults.bool(forKey: DefaultsKeys.spotifyTransferEnabled)
        self.spotifyStatusMessage = isSpotifyTransferEnabled ? "Checking Spotify..." : "Spotify disabled"

        // BPM
        self.isBPMSyncEnabled = userDefaults.bool(forKey: DefaultsKeys.bpmEnabled)

        // Waveform FPS
        let savedFPS = userDefaults.double(forKey: DefaultsKeys.waveformFPS)
        self.waveformFPS = savedFPS > 0 ? savedFPS : 10
    }

    deinit {
        refreshTask?.cancel()
        topologyRefreshTask?.cancel()
    }

    var activeSource: SonosConnectionSource {
        if preferredSource == .cloud, cloudSession != nil {
            return .cloud
        }

        return .local
    }

    var availableSources: [SonosConnectionSource] {
        cloudSession != nil ? [.local, .cloud] : [.local]
    }

    var activeGroups: [SonosGroupModel] {
        activeSource == .cloud ? cloudGroups : localGroups
    }

    var selectedGroup: SonosGroupModel? {
        switch activeSource {
        case .local:
            return localGroups.first(where: { $0.id == selectedLocalGroupID }) ?? localGroups.first
        case .cloud:
            return cloudGroups.first(where: { $0.id == selectedCloudGroupID }) ?? cloudGroups.first
        }
    }

    var selectedHousehold: SonosHouseholdModel? {
        cloudHouseholds.first(where: { $0.id == selectedCloudHouseholdID }) ?? cloudHouseholds.first
    }

    var selectedGroupManagementOptions: [SonosGroupManagementOption] {
        guard let selectedGroup else { return [] }

        var seenPlayerIDs = Set<String>()
        let options = activeGroups.compactMap { group -> [SonosGroupManagementOption]? in
            group.players.compactMap { player in
                guard seenPlayerIDs.insert(player.id).inserted else { return nil }

                let isInSelectedGroup = group.id == selectedGroup.id
                let isCoordinator = selectedGroup.coordinatorID == player.id
                let canJoinSelectedGroup = !isInSelectedGroup
                let canLeaveSelectedGroup = isInSelectedGroup && selectedGroup.players.count > 1 && !isCoordinator

                return SonosGroupManagementOption(
                    player: player,
                    currentGroupID: group.id,
                    currentGroupName: group.name,
                    isInSelectedGroup: isInSelectedGroup,
                    isCoordinator: isCoordinator,
                    canJoinSelectedGroup: canJoinSelectedGroup,
                    canLeaveSelectedGroup: canLeaveSelectedGroup
                )
            }
        }.flatMap { $0 }

        return options.sorted {
            if $0.isInSelectedGroup != $1.isInSelectedGroup {
                return $0.isInSelectedGroup && !$1.isInSelectedGroup
            }

            if $0.isInSelectedGroup && $1.isInSelectedGroup && $0.isCoordinator != $1.isCoordinator {
                return $0.isCoordinator
            }

            return $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
        }
    }

    var menuBarTitle: String {
        if isRefreshing, activeGroups.isEmpty {
            return activeSource == .cloud ? "Cloud" : "Scanning"
        }

        return selectedGroup?.menuBarLabel ?? "Sonos"
    }

    var menuBarSymbol: String {
        "waveform"
    }

    var isCloudConfigured: Bool {
        cloudConfiguration?.isValid == true
    }

    var isCloudConnected: Bool {
        cloudSession != nil
    }

    var isSpotifyDesktopReady: Bool {
        spotifyDesktopStatus.isReady
    }

    var cloudSetupHint: String {
        "Use an HTTPS OAuth broker that holds the Sonos client secret and exchanges tokens on behalf of OpenSonos."
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await localEventClient.setEventHandler { [weak self] event in
            await self?.applyLocalEvent(event)
        }
        await cloudRelayClient.setEventHandler { [weak self] event in
            await self?.applyCloudEvent(event)
        }
        await refreshAll()
        if isSpotifyTransferEnabled {
            await refreshSpotifyDesktopState()
        }
        startRefreshLoop()
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "opensonos" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if let error = queryItems["error"]?.nilIfBlank {
            isCloudAuthenticating = false
            errorMessage = error
            cloudStatusMessage = "Cloud sign-in failed"
            return
        }

        guard let expectedState = pendingOAuthState, let returnedState = queryItems["state"], expectedState == returnedState else {
            isCloudAuthenticating = false
            errorMessage = SonosCloudError.stateMismatch.localizedDescription
            cloudStatusMessage = "Cloud sign-in failed"
            return
        }

        guard let code = queryItems["code"]?.nilIfBlank else {
            isCloudAuthenticating = false
            errorMessage = SonosCloudError.missingAuthorizationCode.localizedDescription
            cloudStatusMessage = "Cloud sign-in failed"
            return
        }

        guard let configuration = cloudConfiguration else {
            isCloudAuthenticating = false
            errorMessage = SonosCloudError.invalidConfiguration.localizedDescription
            return
        }

        do {
            let session = try await cloudClient.exchangeCode(code, configuration: configuration)
            cloudSession = session
            persistCloudSession(session)
            pendingOAuthState = nil
            isCloudAuthenticating = false
            preferredSource = .cloud
            cloudStatusMessage = "Connected to Sonos Cloud"
            await refreshAll()
        } catch {
            isCloudAuthenticating = false
            errorMessage = error.localizedDescription
            cloudStatusMessage = "Cloud sign-in failed"
        }
    }

    func saveCloudConfiguration() {
        userDefaults.set(cloudBrokerURLDraft, forKey: DefaultsKeys.cloudBrokerURL)

        cloudStatusMessage = isCloudConfigured ? "Cloud configured" : initialCloudStatusMessage
    }

    func beginCloudAuthentication() {
        saveCloudConfiguration()
        errorMessage = nil

        guard let configuration = cloudConfiguration else {
            errorMessage = SonosCloudError.invalidConfiguration.localizedDescription
            return
        }

        let state = UUID().uuidString
        pendingOAuthState = state
        isCloudAuthenticating = true
        cloudStatusMessage = "Waiting for Sonos sign-in..."

        Task { [configuration, state] in
            do {
                _ = try await cloudClient.brokerHealth(configuration: configuration)
                let authorizationURL = try await cloudClient.authorizationURL(configuration: configuration, state: state)
                _ = await MainActor.run {
                    NSWorkspace.shared.open(authorizationURL)
                }
            } catch {
                await MainActor.run {
                    self.isCloudAuthenticating = false
                    self.errorMessage = error.localizedDescription
                    self.cloudStatusMessage = "Cloud sign-in failed"
                }
            }
        }
    }

    func disconnectCloud() {
        cloudSession = nil
        cloudGroups = []
        cloudHouseholds = []
        selectedCloudGroupID = nil
        selectedCloudHouseholdID = nil
        pendingOAuthState = nil
        keychain.remove(KeychainKeys.cloudSession)
        preferredSource = .local
        cloudStatusMessage = isCloudConfigured ? "Cloud configured" : initialCloudStatusMessage
        updateStatusFromActiveSource()
        Task { await cloudRelayClient.disconnect() }
    }

    func setSpotifyTransferEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            isSpotifyTransferEnabled = false
            return
        }

        Task {
            await refreshSpotifyDesktopState()
            await MainActor.run {
                if self.spotifyDesktopStatus.isReady {
                    self.isSpotifyTransferEnabled = true
                    self.spotifyStatusMessage = "Spotify Connect ready"
                } else {
                    self.isSpotifyTransferEnabled = false
                    self.errorMessage = self.spotifyStatusMessage
                }
            }
        }
    }

    func refreshSpotifyDesktopState() async {
        guard !isSpotifyRefreshing else { return }
        isSpotifyRefreshing = true
        defer { isSpotifyRefreshing = false }

        do {
            let status = try await spotifyDesktopClient.status()
            spotifyDesktopStatus = status

            guard status.isReady else {
                spotifyDesktopDevices = []
                spotifyDesktopActiveDeviceID = nil
                spotifyStatusMessage = Self.spotifyStatusMessage(for: status)
                return
            }

            let snapshot = try await spotifyDesktopClient.listDevices()
            spotifyDesktopDevices = snapshot.devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            spotifyDesktopActiveDeviceID = snapshot.activeDeviceID
            spotifyStatusMessage = spotifyDesktopDevices.isEmpty ? "No Spotify Connect devices" : "Spotify Connect ready"
        } catch {
            spotifyDesktopDevices = []
            spotifyDesktopActiveDeviceID = nil
            spotifyStatusMessage = error.localizedDescription
        }
    }

    func transferSpotifyPlayback(to device: SpotifyDesktopDevice) {
        performAction {
            try await self.spotifyDesktopClient.transferPlayback(to: device.deviceID)
            await MainActor.run {
                self.spotifyDesktopActiveDeviceID = device.deviceID
                self.spotifyStatusMessage = "Transferred to \(device.name)"
            }
            await self.refreshSpotifyDesktopState()
        }
    }

    func setPreferredSource(_ source: SonosConnectionSource) {
        if source == .cloud, cloudSession == nil {
            errorMessage = "Connect to Sonos Cloud first."
            return
        }

        preferredSource = source
        Task { await syncCloudRelay() }
    }

    func selectGroup(_ group: SonosGroupModel) {
        switch group.source {
        case .local:
            selectedLocalGroupID = group.id
            userDefaults.set(group.id, forKey: DefaultsKeys.selectedLocalGroupID)
        case .cloud:
            selectedCloudGroupID = group.id
            userDefaults.set(group.id, forKey: DefaultsKeys.selectedCloudGroupID)
        }
        rememberSonosTarget(group)
        syncLocalSubscriptions()
    }

    func selectHousehold(_ household: SonosHouseholdModel) {
        selectedCloudHouseholdID = household.id
        userDefaults.set(household.id, forKey: DefaultsKeys.selectedCloudHouseholdID)
        Task { await refreshAll() }
    }

    func refreshButtonTapped() {
        Task { await refreshAll() }
    }

    /// Called when the menu bar popover is opened. Real-time events keep state
    /// fresh while subscriptions are healthy, but an immediate refresh on open
    /// guarantees a current snapshot even if events were missed or dropped.
    func menuDidOpen() {
        Task { await refreshAll() }
    }

    func togglePlaybackButtonTapped() {
        guard let group = selectedGroup else { return }
        rememberSonosTarget(group)
        let targetState: SonosPlaybackState = group.isPlaying ? .paused : .playing
        pendingPlaybackIntent = PlaybackIntent(
            groupID: group.id,
            coordinatorID: group.coordinatorID,
            state: targetState,
            expiresAt: Date().addingTimeInterval(8)
        )
        performAction(optimisticUpdate: {
            self.updateGroup(group) { $0.playbackState = targetState }
        }) {
            switch group.source {
            case .local:
                try await self.controlClient.togglePlayback(for: group)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                if group.isPlaying {
                    try await self.cloudClient.pause(groupID: group.id, accessToken: accessToken)
                } else {
                    try await self.cloudClient.play(groupID: group.id, accessToken: accessToken)
                }
            }
        }
    }

    func nextTrackButtonTapped() {
        guard let group = selectedGroup else { return }
        rememberSonosTarget(group)
        performAction {
            switch group.source {
            case .local:
                try await self.controlClient.nextTrack(group)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                try await self.cloudClient.next(groupID: group.id, accessToken: accessToken)
            }
        }
    }

    func previousTrackButtonTapped() {
        guard let group = selectedGroup else { return }
        rememberSonosTarget(group)
        performAction {
            switch group.source {
            case .local:
                try await self.controlClient.previousTrack(group)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                try await self.cloudClient.previous(groupID: group.id, accessToken: accessToken)
            }
        }
    }

    func toggleMuteButtonTapped() {
        guard let group = selectedGroup else { return }
        rememberSonosTarget(group)
        let targetMute = !group.isMuted
        performAction(optimisticUpdate: {
            self.updateGroup(group) { $0.isMuted = targetMute }
        }) {
            switch group.source {
            case .local:
                try await self.controlClient.setGroupMuted(targetMute, for: group)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                try await self.cloudClient.setGroupMuted(groupID: group.id, muted: targetMute, accessToken: accessToken)
            }
        }
    }

    func setSelectedVolumeFromUI(_ value: Double) {
        guard let group = selectedGroup, !group.volumeIsFixed else { return }
        rememberSonosTarget(group)
        let roundedValue = Int(value.rounded())
        updateGroup(group) { $0.volume = roundedValue }

        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                switch group.source {
                case .local:
                    try await self.controlClient.setGroupVolume(roundedValue, for: group)
                case .cloud:
                    let accessToken = try await self.validCloudAccessToken()
                    try await self.cloudClient.setGroupVolume(groupID: group.id, volume: roundedValue, accessToken: accessToken)
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stepSelectedVolume(_ delta: Int) {
        let nextValue = (selectedGroup?.volume ?? 0) + delta
        setSelectedVolumeFromUI(Double(max(0, min(nextValue, 100))))
    }

    func setSelectedPlayerVolumeFromUI(_ value: Double, playerID: String) {
        guard let group = selectedGroup,
              let player = group.players.first(where: { $0.id == playerID }),
              !player.volumeIsFixed else { return }
        rememberSonosTarget(group)

        let roundedValue = Int(value.rounded())
        updateGroup(group) { currentGroup in
            guard let playerIndex = currentGroup.players.firstIndex(where: { $0.id == playerID }) else { return }
            currentGroup.players[playerIndex].volume = roundedValue
            currentGroup.volume = currentGroup.averagePlayerVolume
        }

        playerVolumeTask?.cancel()
        playerVolumeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                switch group.source {
                case .local:
                    try await self.controlClient.setPlayerVolume(roundedValue, for: player)
                case .cloud:
                    let accessToken = try await self.validCloudAccessToken()
                    try await self.cloudClient.setPlayerVolume(playerID: playerID, volume: roundedValue, accessToken: accessToken)
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func groupManagementActionTapped(_ option: SonosGroupManagementOption) {
        if let selectedGroup {
            rememberSonosTarget(selectedGroup)
        }

        if option.canJoinSelectedGroup {
            addPlayerToSelectedGroup(option.player.id)
        } else if option.canLeaveSelectedGroup {
            removePlayerFromSelectedGroup(option.player.id)
        }
    }

    // MARK: - Spotify

    func refreshBPMIfNeeded() {
        guard isBPMSyncEnabled, let track = selectedGroup?.track else {
            if selectedGroup?.isPlaying != true { currentBPM = nil }
            return
        }

        let key = "\(track.title)|\(track.artist ?? "")"
        guard key != lastBPMTrackKey else { return }
        lastBPMTrackKey = key
        bpmStatusMessage = "Searching..."

        Task { [weak self] in
            guard let self else { return }
            do {
                let tempo = try await self.bpmClient.searchBPM(
                    title: track.title,
                    artist: track.artist
                )

                await MainActor.run {
                    if let tempo {
                        self.currentBPM = tempo
                        self.bpmStatusMessage = "\(Int(tempo)) BPM"
                    } else {
                        self.currentBPM = nil
                        self.bpmStatusMessage = "Track not found"
                    }
                }
            } catch {
                await MainActor.run {
                    self.currentBPM = nil
                    self.bpmStatusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private var initialCloudStatusMessage: String {
        if cloudSession != nil {
            return "Connected to Sonos Cloud"
        }

        if isCloudConfigured {
            return "Cloud configured"
        }

        return "Cloud not configured"
    }

    private static func spotifyStatusMessage(for status: SpotifyDesktopStatus) -> String {
        if !status.helperInstalled {
            return "Install Spotify Desktop to enable Spotify Connect."
        }

        if !status.appRunning {
            return "Open Spotify Desktop to enable Spotify Connect."
        }

        if !status.isLoggedIn {
            return "Log in to Spotify Desktop to enable Spotify Connect."
        }

        return "Spotify Connect ready"
    }

    private var cloudConfiguration: SonosCloudConfiguration? {
        guard
            let brokerValue = cloudBrokerURLDraft.nilIfBlank,
            let brokerURL = URL(string: brokerValue)
        else {
            return nil
        }

        let configuration = SonosCloudConfiguration(brokerBaseURL: brokerURL)
        return configuration.isValid ? configuration : nil
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Safety-net poll only — real-time GENA/WebSocket events drive most
                // updates now, so this just reconciles anything events missed.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshAll()
            }
        }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        errorMessage = nil

        let epoch = actionEpoch
        let localError = await refreshLocalState(epoch: epoch)
        let cloudError = await refreshCloudStateIfNeeded(epoch: epoch)

        lastUpdatedAt = Date()
        isRefreshing = false

        switch activeSource {
        case .local:
            errorMessage = localError?.localizedDescription
        case .cloud:
            errorMessage = cloudError?.localizedDescription
        }

        applyPendingPlaybackIntent()
        updateStatusFromActiveSource()
        rememberPlayingSonosTarget()
        refreshBPMIfNeeded()
        syncLocalSubscriptions()
        await syncCloudRelay()
        if isSpotifyTransferEnabled {
            await refreshSpotifyDesktopState()
        }
    }

    /// Points the local GENA subscriptions at the selected local group's coordinator.
    /// Cheap to call repeatedly — the event client ignores no-op retargets.
    private func syncLocalSubscriptions() {
        guard let group = localGroups.first(where: { $0.id == selectedLocalGroupID }) ?? localGroups.first,
              let baseURL = group.coordinatorBaseURL else { return }
        let coordinatorID = group.coordinatorID
        Task { await localEventClient.setTarget(coordinatorID: coordinatorID, baseURL: baseURL) }
    }

    /// Applies a real-time UPnP event to local state without a full rediscovery.
    private func applyLocalEvent(_ event: SonosLocalEvent) {
        switch event {
        case let .transport(coordinatorID, state, track):
            guard let index = localGroups.firstIndex(where: { $0.coordinatorID == coordinatorID }) else { return }
            if let state, shouldApplyPlaybackState(state, groupID: localGroups[index].id, coordinatorID: coordinatorID) {
                localGroups[index].playbackState = state
            }
            if case let .updated(newTrack) = track {
                localGroups[index].track = newTrack
                resolveArtworkIfNeeded(forCoordinatorID: coordinatorID)
            }
            lastUpdatedAt = Date()
            rememberPlayingSonosTarget()
            refreshBPMIfNeeded()

        case let .groupVolume(coordinatorID, volume, muted):
            guard let index = localGroups.firstIndex(where: { $0.coordinatorID == coordinatorID }) else { return }
            if let volume {
                localGroups[index].volume = volume
            }
            if let muted {
                localGroups[index].isMuted = muted
            }
            lastUpdatedAt = Date()

        case .topologyChanged:
            // Topology events can burst during regrouping — debounce a single rebuild.
            topologyRefreshTask?.cancel()
            topologyRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                _ = await self.refreshLocalState(epoch: self.actionEpoch)
                self.updateStatusFromActiveSource()
                self.syncLocalSubscriptions()
                self.lastUpdatedAt = Date()
            }
        }
    }

    /// Connects (or reconfigures) the cloud relay for the active household's groups.
    /// Only runs when the cloud source is active; disconnects otherwise.
    private func syncCloudRelay() async {
        guard activeSource == .cloud,
              let configuration = cloudConfiguration,
              let householdID = selectedCloudHouseholdID ?? cloudHouseholds.first?.id,
              !cloudGroups.isEmpty else {
            await cloudRelayClient.disconnect()
            return
        }

        guard let accessToken = try? await validCloudAccessToken() else { return }
        let groupIDs = cloudGroups.map(\.id)
        await cloudRelayClient.connect(
            brokerBaseURL: configuration.brokerBaseURL,
            householdID: householdID,
            groupIDs: groupIDs,
            accessToken: accessToken
        )
    }

    /// Applies a real-time cloud event (relayed from a Sonos webhook) to cloud state.
    private func applyCloudEvent(_ event: SonosCloudEvent) {
        switch event {
        case let .playback(groupID, state):
            guard let index = cloudGroups.firstIndex(where: { $0.id == groupID }) else { return }
            if shouldApplyPlaybackState(state, groupID: groupID, coordinatorID: nil) {
                cloudGroups[index].playbackState = state
            }
            lastUpdatedAt = Date()
            rememberPlayingSonosTarget()
            refreshBPMIfNeeded()

        case let .metadata(groupID, track):
            guard let index = cloudGroups.firstIndex(where: { $0.id == groupID }) else { return }
            cloudGroups[index].track = track
            lastUpdatedAt = Date()
            refreshBPMIfNeeded()

        case let .groupVolume(groupID, volume, muted):
            guard let index = cloudGroups.firstIndex(where: { $0.id == groupID }) else { return }
            if let volume {
                cloudGroups[index].volume = volume
            }
            if let muted {
                cloudGroups[index].isMuted = muted
            }
            lastUpdatedAt = Date()

        case .groupsChanged:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.refreshCloudStateIfNeeded(epoch: self.actionEpoch)
                self.updateStatusFromActiveSource()
                await self.syncCloudRelay()
                self.lastUpdatedAt = Date()
            }
        }
    }

    /// Whether an incoming playback state should be applied, given a pending toggle
    /// intent. Transient states that contradict the intent are held off until the
    /// intended state is confirmed or the lock expires.
    private func shouldApplyPlaybackState(_ state: SonosPlaybackState, groupID: String, coordinatorID: String?) -> Bool {
        guard let intent = pendingPlaybackIntent else { return true }

        if Date() >= intent.expiresAt {
            pendingPlaybackIntent = nil
            return true
        }

        let matchesTarget = intent.groupID == groupID || (coordinatorID != nil && intent.coordinatorID == coordinatorID)
        guard matchesTarget else { return true }

        if state == intent.state {
            pendingPlaybackIntent = nil // intent confirmed by the speaker
            return true
        }

        return false // contradicting transient state — keep showing the intended one
    }

    /// Re-asserts a pending toggle intent over freshly-fetched state so a full
    /// refresh landing mid-buffer can't momentarily paint the transient state.
    private func applyPendingPlaybackIntent() {
        guard let intent = pendingPlaybackIntent else { return }
        if Date() >= intent.expiresAt {
            pendingPlaybackIntent = nil
            return
        }

        if let index = localGroups.firstIndex(where: { $0.id == intent.groupID || $0.coordinatorID == intent.coordinatorID }) {
            localGroups[index].playbackState = intent.state
        }
        if let index = cloudGroups.firstIndex(where: { $0.id == intent.groupID }) {
            cloudGroups[index].playbackState = intent.state
        }
    }

    /// Fills in album art for an event-updated track when the DIDL metadata omitted it.
    private func resolveArtworkIfNeeded(forCoordinatorID coordinatorID: String) {
        guard let index = localGroups.firstIndex(where: { $0.coordinatorID == coordinatorID }),
              let track = localGroups[index].track,
              track.albumArtURL == nil else { return }

        let title = track.title
        let artist = track.artist
        let album = track.album

        Task { @MainActor [weak self] in
            let url = await ArtworkFallbackClient.shared.artworkURL(artist: artist, album: album, title: title)
            guard let self, let url,
                  let index = self.localGroups.firstIndex(where: { $0.coordinatorID == coordinatorID }),
                  self.localGroups[index].track?.title == title,
                  self.localGroups[index].track?.albumArtURL == nil else { return }
            self.localGroups[index].track?.albumArtURL = url
        }
    }

    private func refreshLocalState(epoch: Int) async -> Error? {
        do {
            let discoveredGroups = try await discoveryClient.discoverGroups()
            // A user acted while this refresh was in flight — its data predates the
            // optimistic change, so discard it rather than clobber the new state.
            guard epoch == actionEpoch else { return nil }
            localGroups = discoveredGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            reconcileLocalSelection()
            return nil
        } catch {
            if activeSource == .local, epoch == actionEpoch {
                localGroups = []
            }
            return error
        }
    }

    private func refreshCloudStateIfNeeded(epoch: Int) async -> Error? {
        guard cloudSession != nil else {
            cloudGroups = []
            cloudHouseholds = []
            cloudStatusMessage = isCloudConfigured ? "Cloud configured" : initialCloudStatusMessage
            return nil
        }

        do {
            let accessToken = try await validCloudAccessToken()
            let rawHouseholds = try await cloudClient.getHouseholds(accessToken: accessToken)

            var envelopeByHouseholdID: [String: SonosCloudGroupsEnvelope] = [:]
            var households: [SonosHouseholdModel] = []

            for rawHousehold in rawHouseholds {
                let envelope = try await cloudClient.getGroups(householdID: rawHousehold.id, accessToken: accessToken)
                envelopeByHouseholdID[rawHousehold.id] = envelope

                let samplePlayers = Array(envelope.players.compactMap { $0.name?.nilIfBlank }.prefix(3))
                let generatedName = rawHousehold.name?.nilIfBlank ?? samplePlayers.first ?? "Household \(rawHousehold.id.prefix(6))"

                households.append(
                    SonosHouseholdModel(
                        id: rawHousehold.id,
                        source: .cloud,
                        name: generatedName,
                        samplePlayers: samplePlayers
                    )
                )
            }

            // A user acted while this refresh was in flight — discard the stale
            // snapshot rather than overwrite the optimistic state.
            guard epoch == actionEpoch else { return nil }
            cloudHouseholds = households
            reconcileCloudHouseholdSelection()

            if let selectedCloudHouseholdID, let envelope = envelopeByHouseholdID[selectedCloudHouseholdID] {
                let builtGroups = try await buildCloudGroups(householdID: selectedCloudHouseholdID, envelope: envelope, accessToken: accessToken)
                guard epoch == actionEpoch else { return nil }
                cloudGroups = builtGroups
            } else {
                cloudGroups = []
            }

            reconcileCloudGroupSelection()
            cloudStatusMessage = "Connected to Sonos Cloud"
            return nil
        } catch {
            if epoch == actionEpoch {
                cloudGroups = []
            }
            cloudStatusMessage = "Cloud refresh failed"
            return error
        }
    }

    private func buildCloudGroups(householdID: String, envelope: SonosCloudGroupsEnvelope, accessToken: String) async throws -> [SonosGroupModel] {
        let playersByID = Dictionary(uniqueKeysWithValues: envelope.players.map { ($0.id, $0) })
        var groups: [SonosGroupModel] = []

        for cloudGroup in envelope.groups {
            let playback = try? await cloudClient.getPlayback(groupID: cloudGroup.id, accessToken: accessToken)
            let metadata = try? await cloudClient.getMetadata(groupID: cloudGroup.id, accessToken: accessToken)
            let volume = try? await cloudClient.getGroupVolume(groupID: cloudGroup.id, accessToken: accessToken)

            var players: [SonosPlayerModel] = []

            for playerID in cloudGroup.playerIds ?? [] {
                guard let cloudPlayer = playersByID[playerID] else { continue }
                let playerVolume = try? await cloudClient.getPlayerVolume(playerID: cloudPlayer.id, accessToken: accessToken)

                players.append(
                    SonosPlayerModel(
                        id: cloudPlayer.id,
                        name: cloudPlayer.name?.nilIfBlank ?? cloudPlayer.id,
                        baseURL: nil,
                        isCoordinator: cloudPlayer.id == cloudGroup.coordinatorId,
                        webSocketURL: URL(string: cloudPlayer.webSocketUrl ?? ""),
                        capabilities: cloudPlayer.capabilities ?? [],
                        volume: playerVolume?.volume ?? 0,
                        isMuted: playerVolume?.muted ?? false,
                        volumeIsFixed: playerVolume?.fixed ?? false
                    )
                )
            }

            let playbackState = SonosPlaybackState(transportState: playback?.playbackState ?? cloudGroup.playbackState ?? "")
            let groupName = cloudGroup.name?.nilIfBlank ?? players.first(where: { $0.isCoordinator })?.name ?? players.first?.name ?? "Sonos Group"
            let fallbackGroupMute = !players.isEmpty && players.allSatisfy(\.isMuted)
            let fallbackGroupVolume = players.isEmpty ? 0 : Int((Double(players.reduce(0) { $0 + $1.volume }) / Double(players.count)).rounded())

            groups.append(
                SonosGroupModel(
                    id: cloudGroup.id,
                    source: .cloud,
                    householdID: householdID,
                    name: groupName,
                    coordinatorID: cloudGroup.coordinatorId ?? players.first?.id ?? cloudGroup.id,
                    coordinatorBaseURL: nil,
                    players: players,
                    playbackState: playbackState,
                    track: metadata?.trackModel,
                    volume: volume?.volume ?? fallbackGroupVolume,
                    isMuted: volume?.muted ?? fallbackGroupMute,
                    volumeIsFixed: volume?.fixed ?? false
                )
            )
        }

        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func updateStatusFromActiveSource() {
        switch activeSource {
        case .local:
            if localGroups.isEmpty {
                statusMessage = isRefreshing ? "Scanning for Sonos speakers..." : "No local Sonos speakers found"
            } else {
                statusMessage = "Local network ready"
            }
        case .cloud:
            if cloudGroups.isEmpty {
                statusMessage = isRefreshing ? "Refreshing Sonos Cloud..." : "No groups in selected household"
            } else {
                statusMessage = "Cloud household ready"
            }
        }
    }

    private func reconcileLocalSelection() {
        if let selectedLocalGroupID, localGroups.contains(where: { $0.id == selectedLocalGroupID }) {
            return
        }

        if let playingGroup = localGroups.first(where: { $0.isPlaying }) {
            selectedLocalGroupID = playingGroup.id
            userDefaults.set(playingGroup.id, forKey: DefaultsKeys.selectedLocalGroupID)
            return
        }

        if let firstGroup = localGroups.first {
            selectedLocalGroupID = firstGroup.id
            userDefaults.set(firstGroup.id, forKey: DefaultsKeys.selectedLocalGroupID)
        }
    }

    private func reconcileCloudHouseholdSelection() {
        if let selectedCloudHouseholdID, cloudHouseholds.contains(where: { $0.id == selectedCloudHouseholdID }) {
            return
        }

        if let firstHousehold = cloudHouseholds.first {
            selectedCloudHouseholdID = firstHousehold.id
            userDefaults.set(firstHousehold.id, forKey: DefaultsKeys.selectedCloudHouseholdID)
        }
    }

    private func reconcileCloudGroupSelection() {
        if let selectedCloudGroupID, cloudGroups.contains(where: { $0.id == selectedCloudGroupID }) {
            return
        }

        if let playingGroup = cloudGroups.first(where: { $0.isPlaying }) {
            selectedCloudGroupID = playingGroup.id
            userDefaults.set(playingGroup.id, forKey: DefaultsKeys.selectedCloudGroupID)
            return
        }

        if let firstGroup = cloudGroups.first {
            selectedCloudGroupID = firstGroup.id
            userDefaults.set(firstGroup.id, forKey: DefaultsKeys.selectedCloudGroupID)
        }
    }

    private func addPlayerToSelectedGroup(_ playerID: String) {
        guard let selectedGroup else { return }
        guard let option = selectedGroupManagementOptions.first(where: { $0.player.id == playerID }), option.canJoinSelectedGroup else { return }

        performAction(optimisticUpdate: {
            self.modifyActiveGroups { groups in
                if let sourceIdx = groups.firstIndex(where: { $0.id == option.currentGroupID }) {
                    groups[sourceIdx].players.removeAll { $0.id == playerID }
                    if groups[sourceIdx].players.isEmpty {
                        groups.remove(at: sourceIdx)
                    } else {
                        groups[sourceIdx].volume = groups[sourceIdx].averagePlayerVolume
                    }
                }
                if let targetIdx = groups.firstIndex(where: { $0.id == selectedGroup.id }) {
                    groups[targetIdx].players.append(option.player)
                    groups[targetIdx].volume = groups[targetIdx].averagePlayerVolume
                }
            }
        }) {
            switch selectedGroup.source {
            case .local:
                try await self.controlClient.joinPlayer(option.player, to: selectedGroup)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                let playerIDs = Array(Set(selectedGroup.players.map(\.id) + [playerID])).sorted()
                try await self.cloudClient.setGroupMembers(groupID: selectedGroup.id, playerIDs: playerIDs, accessToken: accessToken)
            }
        }
    }

    private func removePlayerFromSelectedGroup(_ playerID: String) {
        guard let selectedGroup else { return }
        guard let option = selectedGroupManagementOptions.first(where: { $0.player.id == playerID }), option.canLeaveSelectedGroup else { return }

        performAction(optimisticUpdate: {
            self.modifyActiveGroups { groups in
                let source = groups.first?.source ?? .local
                let householdID = groups.first(where: { $0.id == selectedGroup.id })?.householdID
                if let sourceIdx = groups.firstIndex(where: { $0.id == selectedGroup.id }) {
                    groups[sourceIdx].players.removeAll { $0.id == playerID }
                    groups[sourceIdx].volume = groups[sourceIdx].averagePlayerVolume
                }
                groups.append(SonosGroupModel(
                    id: playerID,
                    source: source,
                    householdID: householdID,
                    name: option.player.name,
                    coordinatorID: playerID,
                    coordinatorBaseURL: option.player.baseURL,
                    players: [option.player],
                    playbackState: .paused,
                    track: nil,
                    volume: option.player.volume,
                    isMuted: option.player.isMuted,
                    volumeIsFixed: option.player.volumeIsFixed
                ))
            }
        }) {
            switch selectedGroup.source {
            case .local:
                try await self.controlClient.ungroupPlayer(option.player)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                let playerIDs = selectedGroup.players.map(\.id).filter { $0 != playerID }
                guard !playerIDs.isEmpty else { return }
                try await self.cloudClient.setGroupMembers(groupID: selectedGroup.id, playerIDs: playerIDs, accessToken: accessToken)
            }
        }
    }

    private func performAction(
        optimisticUpdate: (() -> Void)? = nil,
        task: @escaping () async throws -> Void
    ) {
        guard !isPerformingAction else { return }

        optimisticUpdate?()

        isPerformingAction = true
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                // No post-action refresh: the optimistic update gives instant feedback
                // and real-time events reconcile the true state moments later. A full
                // refresh here would briefly paint a stale (pre-transition) snapshot.
                try await task()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.pendingPlaybackIntent = nil // failed — let the real state show
                }
            }

            await MainActor.run {
                self.isPerformingAction = false
            }
        }
    }

    private func updateGroup(_ group: SonosGroupModel, using transform: (inout SonosGroupModel) -> Void) {
        actionEpoch &+= 1
        switch group.source {
        case .local:
            guard let index = localGroups.firstIndex(where: { $0.id == group.id }) else { return }
            transform(&localGroups[index])
        case .cloud:
            guard let index = cloudGroups.firstIndex(where: { $0.id == group.id }) else { return }
            transform(&cloudGroups[index])
        }
    }

    private func modifyActiveGroups(_ transform: (inout [SonosGroupModel]) -> Void) {
        actionEpoch &+= 1
        switch activeSource {
        case .local: transform(&localGroups)
        case .cloud: transform(&cloudGroups)
        }
    }

    private func validCloudAccessToken() async throws -> String {
        guard let configuration = cloudConfiguration, let currentSession = cloudSession else {
            throw SonosCloudError.missingAccessToken
        }

        if currentSession.isExpired {
            let refreshedSession = try await cloudClient.refreshSession(currentSession, configuration: configuration)
            cloudSession = refreshedSession
            persistCloudSession(refreshedSession)
            return refreshedSession.accessToken
        }

        return currentSession.accessToken
    }

    private func rememberPlayingSonosTarget() {
        guard let group = activeGroups.first(where: { $0.isPlaying }) else { return }
        rememberSonosTarget(group)
    }

    private func rememberSonosTarget(_ group: SonosGroupModel) {
        userDefaults.set(group.name, forKey: DefaultsKeys.lastUsedSonosGroupName)
        let playerNames = group.players.map(\.name).filter { $0.nilIfBlank != nil }
        lastUsedSonosPlayerNames = playerNames
        userDefaults.set(playerNames, forKey: DefaultsKeys.lastUsedSonosPlayerNames)
    }

    private func persistCloudSession(_ session: SonosCloudSession) {
        guard let data = try? JSONEncoder().encode(session), let json = String(data: data, encoding: .utf8) else {
            return
        }

        keychain.set(json, for: KeychainKeys.cloudSession)
    }

    private static func loadCloudSession(from keychain: SonosKeychainStore) -> SonosCloudSession? {
        guard
            let encoded = keychain.string(for: KeychainKeys.cloudSession),
            let data = encoded.data(using: .utf8),
            let session = try? JSONDecoder().decode(SonosCloudSession.self, from: data)
        else {
            return nil
        }

        return session
    }
}

private struct PlaybackIntent {
    let groupID: String
    let coordinatorID: String
    let state: SonosPlaybackState
    let expiresAt: Date
}

private enum DefaultsKeys {
    static let selectedLocalGroupID = "selectedLocalGroupID"
    static let selectedCloudGroupID = "selectedCloudGroupID"
    static let selectedCloudHouseholdID = "selectedCloudHouseholdID"
    static let preferredSource = "preferredSonosSource"
    static let cloudBrokerURL = "cloudBrokerURL"
    static let defaultCloudBrokerURL = "https://open-sonos-oauth-broker.kinan-lakh.workers.dev"
    static let spotifyTransferEnabled = "spotifyTransferEnabled"
    static let lastUsedSonosGroupName = "lastUsedSonosGroupName"
    static let lastUsedSonosPlayerNames = "lastUsedSonosPlayerNames"
    static let bpmEnabled = "bpmSyncEnabled"
    static let waveformFPS = "waveformFPS"
}

private enum KeychainKeys {
    static let cloudSession = "cloudSession"
}
