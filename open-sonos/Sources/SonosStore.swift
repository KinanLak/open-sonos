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
    var errorMessage: String?
    var statusMessage = "Ready to scan your Sonos system"
    var cloudStatusMessage = "Cloud not configured"
    var lastUpdatedAt: Date?

    var cloudBrokerURLDraft: String

    @ObservationIgnored private let discoveryClient: SonosDiscoveryClient
    @ObservationIgnored private let controlClient: SonosControlClient
    @ObservationIgnored private let cloudClient: SonosCloudClient
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let keychain: SonosKeychainStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var pendingOAuthState: String?
    @ObservationIgnored private var cloudSession: SonosCloudSession?

    init(
        discoveryClient: SonosDiscoveryClient = SonosDiscoveryClient(),
        controlClient: SonosControlClient = SonosControlClient(),
        cloudClient: SonosCloudClient = SonosCloudClient(),
        userDefaults: UserDefaults = .standard,
        keychain: SonosKeychainStore = SonosKeychainStore()
    ) {
        self.discoveryClient = discoveryClient
        self.controlClient = controlClient
        self.cloudClient = cloudClient
        self.userDefaults = userDefaults
        self.keychain = keychain

        self.cloudBrokerURLDraft = userDefaults.string(forKey: DefaultsKeys.cloudBrokerURL) ?? DefaultsKeys.defaultCloudBrokerURL
        self.selectedLocalGroupID = userDefaults.string(forKey: DefaultsKeys.selectedLocalGroupID)
        self.selectedCloudGroupID = userDefaults.string(forKey: DefaultsKeys.selectedCloudGroupID)
        self.selectedCloudHouseholdID = userDefaults.string(forKey: DefaultsKeys.selectedCloudHouseholdID)
        self.preferredSource = SonosConnectionSource(rawValue: userDefaults.string(forKey: DefaultsKeys.preferredSource) ?? "local") ?? .local
        self.cloudSession = Self.loadCloudSession(from: keychain)
        self.cloudStatusMessage = initialCloudStatusMessage
    }

    deinit {
        refreshTask?.cancel()
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
        if activeSource == .cloud {
            return selectedGroup?.isPlaying == true ? "cloud.fill" : "cloud"
        }

        return selectedGroup?.isPlaying == true ? "speaker.wave.2.fill" : "speaker.wave.2"
    }

    var isCloudConfigured: Bool {
        cloudConfiguration?.isValid == true
    }

    var isCloudConnected: Bool {
        cloudSession != nil
    }

    var cloudSetupHint: String {
        "Use an HTTPS OAuth broker that holds the Sonos client secret and exchanges tokens on behalf of OpenSonos."
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refreshAll()
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
    }

    func setPreferredSource(_ source: SonosConnectionSource) {
        if source == .cloud, cloudSession == nil {
            errorMessage = "Connect to Sonos Cloud first."
            return
        }

        preferredSource = source
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
    }

    func selectHousehold(_ household: SonosHouseholdModel) {
        selectedCloudHouseholdID = household.id
        userDefaults.set(household.id, forKey: DefaultsKeys.selectedCloudHouseholdID)
        Task { await refreshAll() }
    }

    func refreshButtonTapped() {
        Task { await refreshAll() }
    }

    func togglePlaybackButtonTapped() {
        guard let group = selectedGroup else { return }
        performAction(for: group, optimisticUpdate: { currentGroup in
            currentGroup.playbackState = currentGroup.playbackState == .playing ? .paused : .playing
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
        performAction(for: group) {
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
        performAction(for: group) {
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
        let targetMute = !group.isMuted
        performAction(for: group, optimisticUpdate: { currentGroup in
            currentGroup.isMuted = targetMute
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
        let roundedValue = Int(value.rounded())
        performAction(for: group, optimisticUpdate: { currentGroup in
            currentGroup.volume = roundedValue
        }) {
            switch group.source {
            case .local:
                try await self.controlClient.setGroupVolume(roundedValue, for: group)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                try await self.cloudClient.setGroupVolume(groupID: group.id, volume: roundedValue, accessToken: accessToken)
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

        let roundedValue = Int(value.rounded())
        performAction(for: group, optimisticUpdate: { currentGroup in
            guard let playerIndex = currentGroup.players.firstIndex(where: { $0.id == playerID }) else { return }
            currentGroup.players[playerIndex].volume = roundedValue
            currentGroup.volume = currentGroup.averagePlayerVolume
        }) {
            switch group.source {
            case .local:
                try await self.controlClient.setPlayerVolume(roundedValue, for: player)
            case .cloud:
                let accessToken = try await self.validCloudAccessToken()
                try await self.cloudClient.setPlayerVolume(playerID: playerID, volume: roundedValue, accessToken: accessToken)
            }
        }
    }

    func groupManagementActionTapped(_ option: SonosGroupManagementOption) {
        if option.canJoinSelectedGroup {
            addPlayerToSelectedGroup(option.player.id)
        } else if option.canLeaveSelectedGroup {
            removePlayerFromSelectedGroup(option.player.id)
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
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshAll()
            }
        }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        errorMessage = nil

        let localError = await refreshLocalState()
        let cloudError = await refreshCloudStateIfNeeded()

        lastUpdatedAt = Date()
        isRefreshing = false

        switch activeSource {
        case .local:
            errorMessage = localError?.localizedDescription
        case .cloud:
            errorMessage = cloudError?.localizedDescription
        }

        updateStatusFromActiveSource()
    }

    private func refreshLocalState() async -> Error? {
        do {
            let discoveredGroups = try await discoveryClient.discoverGroups()
            localGroups = discoveredGroups
            reconcileLocalSelection()
            return nil
        } catch {
            if activeSource == .local {
                localGroups = []
            }
            return error
        }
    }

    private func refreshCloudStateIfNeeded() async -> Error? {
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

            cloudHouseholds = households
            reconcileCloudHouseholdSelection()

            if let selectedCloudHouseholdID, let envelope = envelopeByHouseholdID[selectedCloudHouseholdID] {
                cloudGroups = try await buildCloudGroups(householdID: selectedCloudHouseholdID, envelope: envelope, accessToken: accessToken)
            } else {
                cloudGroups = []
            }

            reconcileCloudGroupSelection()
            cloudStatusMessage = "Connected to Sonos Cloud"
            return nil
        } catch {
            cloudGroups = []
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

        performAction(for: selectedGroup) {
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

        performAction(for: selectedGroup) {
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
        for group: SonosGroupModel,
        optimisticUpdate: ((inout SonosGroupModel) -> Void)? = nil,
        task: @escaping () async throws -> Void
    ) {
        guard !isPerformingAction else { return }

        if let optimisticUpdate {
            updateGroup(group, using: optimisticUpdate)
        }

        isPerformingAction = true
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                try await task()
                await self.refreshAll()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                self.isPerformingAction = false
            }
        }
    }

    private func updateGroup(_ group: SonosGroupModel, using transform: (inout SonosGroupModel) -> Void) {
        switch group.source {
        case .local:
            guard let index = localGroups.firstIndex(where: { $0.id == group.id }) else { return }
            transform(&localGroups[index])
        case .cloud:
            guard let index = cloudGroups.firstIndex(where: { $0.id == group.id }) else { return }
            transform(&cloudGroups[index])
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

private enum DefaultsKeys {
    static let selectedLocalGroupID = "selectedLocalGroupID"
    static let selectedCloudGroupID = "selectedCloudGroupID"
    static let selectedCloudHouseholdID = "selectedCloudHouseholdID"
    static let preferredSource = "preferredSonosSource"
    static let cloudBrokerURL = "cloudBrokerURL"
    static let defaultCloudBrokerURL = "https://open-sonos-oauth-broker.kinan-lakh.workers.dev"
}

private enum KeychainKeys {
    static let cloudSession = "cloudSession"
}
