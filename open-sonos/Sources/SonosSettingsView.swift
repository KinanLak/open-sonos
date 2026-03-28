import ServiceManagement
import SwiftUI

struct SonosSettingsView: View {
    let store: SonosStore
    let hotkeyManager: HotkeyManager

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            groupPickerSection

            if let group = store.selectedGroup, group.players.count > 1 {
                roomVolumeSection(group)
            }

            if store.selectedGroup != nil {
                groupManagementSection
            }

            cloudSection
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

    // MARK: - Cloud

    private var cloudSection: some View {
        Section("Sonos Cloud") {
            TextField("Broker URL", text: Binding(
                get: { store.cloudBrokerURLDraft },
                set: { store.cloudBrokerURLDraft = $0 }
            ))

            Text("The broker keeps the Sonos client secret server-side and exchanges tokens on behalf of OpenSonos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save") {
                    store.saveCloudConfiguration()
                }

                Button(store.isCloudConnected ? "Reconnect" : "Connect") {
                    store.beginCloudAuthentication()
                }

                if store.isCloudConnected {
                    Button("Disconnect", role: .destructive) {
                        store.disconnectCloud()
                    }
                }

                Spacer()

                Text(store.cloudStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
