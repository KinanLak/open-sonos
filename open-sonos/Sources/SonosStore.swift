import Foundation
import Observation

@MainActor
@Observable
final class SonosStore {
    var groups: [SonosGroupModel] = []
    var selectedGroupID: String?
    var isRefreshing = false
    var isPerformingAction = false
    var errorMessage: String?
    var statusMessage = "Ready to scan your Sonos system"
    var lastUpdatedAt: Date?

    @ObservationIgnored private let discoveryClient: SonosDiscoveryClient
    @ObservationIgnored private let controlClient: SonosControlClient
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let selectedGroupDefaultsKey = "selectedSonosGroupID"
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(
        discoveryClient: SonosDiscoveryClient = SonosDiscoveryClient(),
        controlClient: SonosControlClient = SonosControlClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.discoveryClient = discoveryClient
        self.controlClient = controlClient
        self.userDefaults = userDefaults
    }

    deinit {
        refreshTask?.cancel()
    }

    var selectedGroup: SonosGroupModel? {
        groups.first(where: { $0.id == selectedGroupID }) ?? groups.first
    }

    var menuBarTitle: String {
        if isRefreshing, groups.isEmpty {
            return "Scanning"
        }

        return selectedGroup?.menuBarLabel ?? "Sonos"
    }

    var menuBarSymbol: String {
        selectedGroup?.isPlaying == true ? "speaker.wave.2.fill" : "speaker.wave.2"
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        selectedGroupID = userDefaults.string(forKey: selectedGroupDefaultsKey)
        await refresh()
        startRefreshLoop()
    }

    func refreshButtonTapped() {
        Task { await refresh() }
    }

    func selectGroup(_ group: SonosGroupModel) {
        selectedGroupID = group.id
        userDefaults.set(group.id, forKey: selectedGroupDefaultsKey)
    }

    func togglePlaybackButtonTapped() {
        guard let group = selectedGroup else { return }
        performAction(optimisticUpdate: { currentGroup in
            currentGroup.playbackState = currentGroup.playbackState == .playing ? .paused : .playing
        }) {
            try await self.controlClient.togglePlayback(for: group)
        }
    }

    func nextTrackButtonTapped() {
        guard let group = selectedGroup else { return }
        performAction {
            try await self.controlClient.nextTrack(group)
        }
    }

    func previousTrackButtonTapped() {
        guard let group = selectedGroup else { return }
        performAction {
            try await self.controlClient.previousTrack(group)
        }
    }

    func toggleMuteButtonTapped() {
        guard let group = selectedGroup else { return }
        let targetMute = !group.isMuted
        performAction(optimisticUpdate: { currentGroup in
            currentGroup.isMuted = targetMute
        }) {
            try await self.controlClient.setGroupMuted(targetMute, for: group)
        }
    }

    func setSelectedVolumeFromUI(_ value: Double) {
        guard let group = selectedGroup else { return }
        let roundedValue = Int(value.rounded())
        performAction(optimisticUpdate: { currentGroup in
            currentGroup.volume = roundedValue
        }) {
            try await self.controlClient.setGroupVolume(roundedValue, for: group)
        }
    }

    func stepSelectedVolume(_ delta: Int) {
        let nextValue = (selectedGroup?.volume ?? 0) + delta
        setSelectedVolumeFromUI(Double(max(0, min(nextValue, 100))))
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        errorMessage = nil
        statusMessage = groups.isEmpty ? "Scanning for Sonos speakers..." : "Refreshing Sonos status..."

        do {
            let discoveredGroups = try await discoveryClient.discoverGroups()
            groups = discoveredGroups
            reconcileSelection()
            lastUpdatedAt = Date()

            if groups.isEmpty {
                statusMessage = "No Sonos speakers found"
            } else {
                statusMessage = "Updated just now"
            }
        } catch {
            errorMessage = error.localizedDescription
            if groups.isEmpty {
                statusMessage = "Could not discover your Sonos speakers"
            }
        }

        isRefreshing = false
    }

    private func reconcileSelection() {
        if let selectedGroupID, groups.contains(where: { $0.id == selectedGroupID }) {
            return
        }

        if let playingGroup = groups.first(where: { $0.isPlaying }) {
            selectGroup(playingGroup)
            return
        }

        if let firstGroup = groups.first {
            selectGroup(firstGroup)
        }
    }

    private func performAction(
        optimisticUpdate: ((inout SonosGroupModel) -> Void)? = nil,
        task: @escaping () async throws -> Void
    ) {
        guard !isPerformingAction else { return }

        if let optimisticUpdate {
            updateSelectedGroup(using: optimisticUpdate)
        }

        isPerformingAction = true
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                try await task()
                await self.refresh()
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

    private func updateSelectedGroup(using transform: (inout SonosGroupModel) -> Void) {
        guard let selectedGroupID, let index = groups.firstIndex(where: { $0.id == selectedGroupID }) else {
            return
        }

        transform(&groups[index])
    }
}
