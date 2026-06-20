import ServiceManagement
import SwiftUI

struct SonosSettingsView: View {
    let store: SonosStore
    let hotkeyManager: HotkeyManager

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isEditingBrokerURL = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 520)
        .onAppear {
            NSApp.activate()
            Task { await store.refreshSpotifyDesktopState() }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Application") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            connectionSection
            waveformSection
            spotifySection
            cloudSection
            groupPickerSection

            if let group = store.selectedGroup, group.players.count > 1 {
                roomVolumeSection(group)
            }

            if store.selectedGroup != nil {
                groupManagementSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section("Playback") {
                shortcutRow(.playPause)
                shortcutRow(.nextTrack)
                shortcutRow(.previousTrack)
            }

            Section("Volume") {
                shortcutRow(.volumeUp)
                shortcutRow(.volumeDown)
                shortcutRow(.toggleMute)
            }

            Section {
                Text("Shortcuts work globally while the app is running. A Now Playing popup will appear briefly when a shortcut is triggered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: HotkeyAction) -> some View {
        LabeledContent {
            ShortcutRecorderView(
                keyCombo: Binding(
                    get: { hotkeyManager.bindings[action] },
                    set: { hotkeyManager.setBinding($0, for: action) }
                ),
                hotkeyManager: hotkeyManager
            )
        } label: {
            Label(action.displayName, systemImage: action.symbolName)
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            if store.availableSources.count > 1 {
                Picker("Source", selection: Binding(
                    get: { store.preferredSource },
                    set: { store.setPreferredSource($0) }
                )) {
                    ForEach(store.availableSources) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            }

            LabeledContent("Status", value: store.statusMessage)

            if store.activeSource == .cloud, store.cloudHouseholds.count > 1 {
                Picker("Household", selection: Binding(
                    get: { store.selectedCloudHouseholdID ?? "" },
                    set: { id in
                        if let household = store.cloudHouseholds.first(where: { $0.id == id }) {
                            store.selectHousehold(household)
                        }
                    }
                )) {
                    ForEach(store.cloudHouseholds) { household in
                        Text(household.name).tag(household.id)
                    }
                }
            }

            TimelineView(.periodic(from: .now, by: 5)) { _ in
                if let updatedAt = store.lastUpdatedAt {
                    LabeledContent("Last refresh", value: relativeTimeString(from: updatedAt))
                }
            }
        }
    }

    // MARK: - Group Picker

    @ViewBuilder
    private var groupPickerSection: some View {
        if store.activeGroups.count > 1 {
            Section("Active Group") {
                Picker("Group", selection: Binding(
                    get: { store.selectedGroup?.id ?? "" },
                    set: { id in
                        if let group = store.activeGroups.first(where: { $0.id == id }) {
                            store.selectGroup(group)
                        }
                    }
                )) {
                    ForEach(store.activeGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
            }
        }
    }

    // MARK: - Room Volumes

    private func roomVolumeSection(_ group: SonosGroupModel) -> some View {
        Section("Room Volumes") {
            ForEach(currentPlayers(for: group).sorted(by: \.name)) { player in
                HStack(spacing: 8) {
                    Text(player.name)
                        .lineLimit(1)
                        .frame(minWidth: 80, alignment: .leading)

                    SonosSlider(
                        value: Binding(
                            get: { Double(resolvedVolume(for: player, in: group)) },
                            set: { store.setSelectedPlayerVolumeFromUI($0, playerID: player.id) }
                        ),
                        disabled: player.volumeIsFixed,
                        height: 8
                    )

                    Text("\(resolvedVolume(for: player, in: group))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Group Management

    @ViewBuilder
    private var groupManagementSection: some View {
        if let selectedGroup = store.selectedGroup {
            Section("Group - \(selectedGroup.name)") {
                SonosGroupManagementView(store: store)
            }
        }
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        Section("Waveform") {
            Toggle("Sync waveform animation to BPM", isOn: Binding(
                get: { store.isBPMSyncEnabled },
                set: { store.isBPMSyncEnabled = $0 }
            ))

            if store.isBPMSyncEnabled, !store.bpmStatusMessage.isEmpty {
                Text(store.bpmStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Waveform FPS (menu bar)") {
                HStack(spacing: 8) {
                    let steps: [Double] = [5, 10, 15, 20, 24, 30, 60, 120]
                    let currentIndex = Double(steps.enumerated().min(by: {
                        abs($0.element - store.waveformFPS) < abs($1.element - store.waveformFPS)
                    })?.offset ?? 0)

                    Slider(
                        value: Binding(
                            get: { currentIndex },
                            set: { store.waveformFPS = steps[Int($0)] }
                        ),
                        in: 0...Double(steps.count - 1),
                        step: 1
                    )
                    .frame(width: 140)

                    Text("\(Int(store.waveformFPS))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Spotify Connect

    private var spotifySection: some View {
        Section("Spotify Connect") {
            Toggle("Show Spotify transfer menu", isOn: Binding(
                get: { store.isSpotifyTransferEnabled },
                set: { store.setSpotifyTransferEnabled($0) }
            ))
            .disabled(!store.isSpotifyDesktopReady && !store.isSpotifyTransferEnabled)

            if store.isSpotifyTransferEnabled {
                Text("Uses Spotify Desktop's bundled command-line helper. No Spotify API token or Client ID is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Label(spotifyStatusLabel, systemImage: store.isSpotifyDesktopReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(store.isSpotifyDesktopReady ? .green : .red)

                        Button {
                            Task { await store.refreshSpotifyDesktopState() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.isSpotifyRefreshing)
                    }
                }
            }
        }
    }

    // MARK: - Cloud

    private var cloudSection: some View {
        Section {
            if isEditingBrokerURL {
                TextField("Broker URL", text: Binding(
                    get: { store.cloudBrokerURLDraft },
                    set: { store.cloudBrokerURLDraft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { isEditingBrokerURL = false }
            }

            HStack {
                Button(store.isCloudConnected ? "Disconnect" : "Connect", role: store.isCloudConnected ? .destructive : nil) {
                    if store.isCloudConnected {
                        store.disconnectCloud()
                    } else {
                        store.beginCloudAuthentication()
                    }
                }

                Spacer()

                Text(store.cloudStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Sonos Cloud")
                Spacer()
                Button(isEditingBrokerURL ? "Done" : "Edit") {
                    isEditingBrokerURL.toggle()
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Helpers

    private func currentPlayers(for group: SonosGroupModel) -> [SonosPlayerModel] {
        (store.selectedGroup ?? group).players
    }

    private func resolvedVolume(for player: SonosPlayerModel, in group: SonosGroupModel) -> Int {
        let currentGroup = store.selectedGroup ?? group
        return currentGroup.players.first(where: { $0.id == player.id })?.volume ?? player.volume
    }

    private func relativeTimeString(from date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var spotifyStatusLabel: String {
        let status = store.spotifyDesktopStatus
        if !status.helperInstalled { return "Helper missing" }
        if !status.appRunning { return "Spotify not running" }
        if !status.isLoggedIn { return "Not logged in" }
        return "Ready"
    }
}
