import SwiftUI

struct SonosMenuView: View {
    let store: SonosStore
    @Environment(\.openWindow) private var openWindow
    @State private var showsGroupEdit = false
    @State private var showsSpeakers = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                if let group = store.selectedGroup {
                    SonosPlaybackRowView(store: store, group: group)
                        .padding(12)

                    Divider()

                    SonosVolumeRowView(store: store, group: group)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    emptyState
                }

                Divider()

                if !store.activeGroups.isEmpty {
                    groupList
                }

                if let group = store.selectedGroup, group.players.count > 1 {
                    speakerVolumeSection(group)
                }

                if store.selectedGroup != nil, store.selectedGroupManagementOptions.count > 1 {
                    groupEditSection
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }

                Divider()
                footer
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PanelConfigurator())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)

            Text(store.isRefreshing ? "Scanning..." : "No speakers found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Group list

    private var groupList: some View {
        VStack(spacing: 1) {
            ForEach(store.activeGroups.sorted(by: \.name)) { group in
                SonosGroupRowView(
                    group: group,
                    isSelected: group.id == store.selectedGroup?.id,
                    onSelect: { store.selectGroup(group) }
                )
            }
        }
        .padding(6)
    }

    // MARK: - Speaker volumes (custom disclosure)

    private func speakerVolumeSection(_ group: SonosGroupModel) -> some View {
        let currentGroup = store.selectedGroup ?? group
        let sortedPlayers = currentGroup.players.sorted(by: \.name)

        return VStack(spacing: 0) {
            disclosureHeader(
                label: "\(currentGroup.players.count) speakers",
                isExpanded: showsSpeakers
            ) {
                updateDisclosureState {
                    showsSpeakers.toggle()
                }
            }

            if showsSpeakers {
                VStack(spacing: 6) {
                    ForEach(sortedPlayers) { player in
                        HStack(spacing: 6) {
                            Text(player.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                                .lineLimit(1)

                            SonosSlider(
                                value: Binding(
                                    get: { Double(resolvedVolume(for: player, in: currentGroup)) },
                                    set: { store.setSelectedPlayerVolumeFromUI($0, playerID: player.id) }
                                ),
                                disabled: resolvedIsFixed(for: player, in: currentGroup),
                                height: 4
                            )

                            Text("\(resolvedVolume(for: player, in: currentGroup))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Group edit (custom disclosure)

    private var groupEditSection: some View {
        VStack(spacing: 0) {
            disclosureHeader(
                label: "Edit group",
                isExpanded: showsGroupEdit
            ) {
                updateDisclosureState {
                    showsGroupEdit.toggle()
                }
            }

            if showsGroupEdit {
                VStack(spacing: 1) {
                    ForEach(store.selectedGroupManagementOptions) { option in
                        Button {
                            store.groupManagementActionTapped(option)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: option.isInSelectedGroup ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(option.isInSelectedGroup ? Color.accentColor : Color.secondary.opacity(0.4))
                                    .font(.caption)

                                Text(option.player.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)

                                if option.isCoordinator {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Color.secondary)
                                }

                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(option.actionLabel == nil)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Shared disclosure header

    private func disclosureHeader(label: String, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "settings")
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            if store.availableSources.count > 1 {
                Button {
                    let next: SonosConnectionSource = store.preferredSource == .local ? .cloud : .local
                    store.setPreferredSource(next)
                } label: {
                    Image(systemName: store.activeSource == .cloud ? "cloud.fill" : "antenna.radiowaves.left.and.right")
                }
                .help(store.activeSource == .cloud ? "Switch to Local" : "Switch to Cloud")
            }

            Spacer()

            if store.isRefreshing || store.isPerformingAction {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .frame(width: 14, height: 14)
            }

            Button {
                store.refreshButtonTapped()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .help("Refresh")

            Divider()
                .frame(height: 12)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func resolvedVolume(for player: SonosPlayerModel, in group: SonosGroupModel) -> Int {
        group.players.first(where: { $0.id == player.id })?.volume ?? player.volume
    }

    private func resolvedIsFixed(for player: SonosPlayerModel, in group: SonosGroupModel) -> Bool {
        group.players.first(where: { $0.id == player.id })?.volumeIsFixed ?? player.volumeIsFixed
    }

    private func updateDisclosureState(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

// MARK: - Panel configurator (prevents auto-hide)

private struct PanelConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelConfigView {
        PanelConfigView()
    }

    func updateNSView(_: PanelConfigView, context: Context) {}

    class PanelConfigView: NSView {
        private var lastSyncedBounds: CGSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let panel = window as? NSPanel else { return }
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            syncPanelHeightIfNeeded()
        }

        override func layout() {
            super.layout()
            syncPanelHeightIfNeeded()
        }

        private func syncPanelHeightIfNeeded() {
            guard let currentPanel = self.window as? NSPanel, bounds.height > 0 else { return }

            let desiredBounds = bounds.size
            guard abs(desiredBounds.height - lastSyncedBounds.height) > 0.5 else { return }

            let currentContentHeight = currentPanel.contentView?.bounds.height ?? 0
            let delta = desiredBounds.height - currentContentHeight
            lastSyncedBounds = desiredBounds

            guard abs(delta) > 0.5 else { return }

            var frame = currentPanel.frame
            frame.size.height += delta
            frame.origin.y = currentPanel.frame.maxY - frame.size.height
            currentPanel.setFrame(frame, display: false)

            #if DEBUG
            print("[PanelConfigurator] content=\(desiredBounds.height) panel=\(frame.height) delta=\(delta)")
            #endif
        }
    }
}

// MARK: - Sorting helper

extension Sequence {
    func sorted(by keyPath: KeyPath<Element, String>) -> [Element] {
        sorted { $0[keyPath: keyPath].localizedCaseInsensitiveCompare($1[keyPath: keyPath]) == .orderedAscending }
    }
}
