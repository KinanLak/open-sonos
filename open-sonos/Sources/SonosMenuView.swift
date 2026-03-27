import SwiftUI

struct SonosMenuView: View {
    let store: SonosStore
    @State private var showsCloudSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                sourcePickerSection

                if store.activeSource == .cloud, !store.cloudHouseholds.isEmpty {
                    householdSection
                }

                if let selectedGroup = store.selectedGroup {
                    SonosPlaybackRowView(store: store, group: selectedGroup)
                    SonosVolumeRowView(store: store, group: selectedGroup)
                }

                groupSection
                cloudSection

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Button("Refresh") {
                        store.refreshButtonTapped()
                    }
                    .keyboardShortcut("r", modifiers: [.command])

                    Spacer()

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: [.command])
                }
            }
            .padding(14)
        }
        .frame(width: 430, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenSonos")
                    .font(.headline)

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(store.activeSource == .cloud ? store.cloudStatusMessage : "Direct local network control")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let updatedAt = store.lastUpdatedAt {
                    Text(updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if store.isRefreshing || store.isPerformingAction || store.isCloudAuthenticating {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var sourcePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.availableSources.count > 1 {
                Text("Connection")
                    .font(.subheadline.weight(.semibold))

                Picker("Connection", selection: Binding(
                    get: { store.preferredSource },
                    set: { store.setPreferredSource($0) }
                )) {
                    ForEach(store.availableSources) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var householdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Households")
                .font(.subheadline.weight(.semibold))

            if store.cloudHouseholds.count > 1 {
                VStack(spacing: 8) {
                    ForEach(store.cloudHouseholds) { household in
                        Button {
                            store.selectHousehold(household)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: household.id == store.selectedHousehold?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(household.id == store.selectedHousehold?.id ? Color.accentColor : Color.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(household.name)
                                        .foregroundStyle(.primary)
                                    Text(household.detailLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(household.id == store.selectedHousehold?.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let household = store.selectedHousehold {
                Text("Using \(household.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text(store.activeSource == .cloud ? "Groups" : "Rooms")
                .font(.subheadline.weight(.semibold))

            if store.activeGroups.isEmpty {
                Text(store.activeSource == .cloud ? "No Sonos cloud groups are available yet for the selected household." : "No Sonos speakers found yet. Make sure your Mac is on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.activeGroups) { group in
                        SonosGroupRowView(
                            group: group,
                            isSelected: group.id == store.selectedGroup?.id,
                            onSelect: { store.selectGroup(group) }
                        )
                    }
                }
            }
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Button {
                showsCloudSetup.toggle()
            } label: {
                HStack {
                    Text("Sonos Cloud")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(store.isCloudConnected ? "Connected" : (store.isCloudConfigured ? "Configured" : "Setup"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: showsCloudSetup ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showsCloudSetup {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.cloudSetupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("https://open-sonos-oauth-broker.kinan-lakh.workers.dev", text: Binding(
                        get: { store.cloudBrokerURLDraft },
                        set: { store.cloudBrokerURLDraft = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Text("The broker keeps the Sonos client secret server-side and uses your public callback page for OAuth.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Save") {
                            store.saveCloudConfiguration()
                        }

                        Button(store.isCloudConnected ? "Reconnect" : "Connect") {
                            store.beginCloudAuthentication()
                        }

                        if store.isCloudConnected {
                            Button("Disconnect") {
                                store.disconnectCloud()
                            }
                        }

                        Spacer()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
