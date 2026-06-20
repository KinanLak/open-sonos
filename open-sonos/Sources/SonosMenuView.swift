import SwiftUI

struct SonosMenuView: View {
    let store: SonosStore
    @Environment(\.openWindow) private var openWindow
    @State private var showsSpeakerList = false

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

                if store.selectedGroup != nil, store.selectedGroupManagementOptions.count > 1 {
                    speakersSection
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
        .fixedSize(horizontal: false, vertical: true)
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
                    bpm: group.id == store.selectedGroup?.id ? store.currentBPM : nil,
                    onSelect: { store.selectGroup(group) }
                )
            }
        }
        .padding(6)
    }

    // MARK: - Unified speakers section

    private var speakersSection: some View {
        let options = store.selectedGroupManagementOptions
        let activeCount = options.filter(\.isInSelectedGroup).count

        return VStack(spacing: 0) {
            disclosureHeader(
                label: "\(activeCount) playing speaker\(activeCount == 1 ? "" : "s")",
                isExpanded: showsSpeakerList
            ) {
                updateDisclosureState {
                    showsSpeakerList.toggle()
                }
            }

            if showsSpeakerList {
                VStack(spacing: 4) {
                    ForEach(options) { option in
                        speakerRow(option: option)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .animation(.easeInOut(duration: 0.35), value: options.map(\.isInSelectedGroup))
            }
        }
    }

    private func speakerRow(option: SonosGroupManagementOption) -> some View {
        let isActive = option.isInSelectedGroup

        return HStack(spacing: 6) {
            Button {
                store.groupManagementActionTapped(option)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                        .font(.caption)

                    Text(option.player.name)
                        .font(.caption)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)

                    if option.isCoordinator {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if isActive {
                SonosSlider(
                    value: Binding(
                        get: { Double(option.player.volume) },
                        set: { store.setSelectedPlayerVolumeFromUI($0, playerID: option.player.id) }
                    ),
                    disabled: option.player.volumeIsFixed,
                    height: 4
                )
                .frame(width: 80)

                Text("\(option.player.volume)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
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
        HStack(spacing: 2) {
            footerIconButton(systemName: "gearshape", help: "Settings") {
                openWindow(id: "settings")
                NSApp.activate()
            }

            if store.availableSources.count > 1 {
                footerIconButton(
                    systemName: store.activeSource == .cloud ? "cloud.fill" : "antenna.radiowaves.left.and.right",
                    help: store.activeSource == .cloud ? "Switch to Local" : "Switch to Cloud"
                ) {
                    let next: SonosConnectionSource = store.preferredSource == .local ? .cloud : .local
                    store.setPreferredSource(next)
                }
            }

            if store.isSpotifyTransferEnabled {
                Menu {
                    if store.spotifyDesktopDevices.isEmpty {
                        Text(store.spotifyStatusMessage)
                    } else {
                        Picker(
                            selection: Binding<String?>(
                                get: { store.spotifyDesktopActiveDeviceID },
                                set: { newID in
                                    guard let newID, newID != store.spotifyDesktopActiveDeviceID,
                                          let device = store.spotifyDesktopDevices.first(where: { $0.deviceID == newID })
                                    else { return }
                                    store.transferSpotifyPlayback(to: device)
                                }
                            )
                        ) {
                            ForEach(store.spotifyDesktopDevices, id: \.deviceID) { device in
                                Label(spotifyDeviceMenuTitle(device), systemImage: spotifyDeviceSymbol(device))
                                    .tag(Optional(device.deviceID))
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                        .disabled(store.isPerformingAction)

                        Divider()
                    }

                    Button {
                        Task { await store.refreshSpotifyDesktopState() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    SpotifyMarkView()
                        .frame(width: 17, height: 17)
                        .frame(width: footerIconWidth, height: footerIconHeight)
                        .contentShape(Rectangle())
                }
                .disabled(!store.isSpotifyDesktopReady && store.spotifyDesktopDevices.isEmpty)
                .help(store.spotifyStatusMessage)
                .task {
                    await store.refreshSpotifyDesktopState()
                }
            }

            Spacer()

            if store.isRefreshing || store.isPerformingAction || store.isSpotifyRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .frame(width: 14, height: 14)
            }

            footerIconButton(systemName: "arrow.clockwise", help: "Refresh") {
                store.refreshButtonTapped()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
            .padding(.leading, 6)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Uniform metrics so every footer control shares the same optical size & hit area.
    private var footerIconWidth: CGFloat { 28 }
    private var footerIconHeight: CGFloat { 24 }

    private func footerIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: footerIconWidth, height: footerIconHeight)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    private func spotifyDeviceSymbol(_ device: SpotifyDesktopDevice) -> String {
        switch device.deviceType.lowercased() {
        case "computer": return "desktopcomputer"
        case "smartphone": return "iphone"
        case "tablet": return "ipad"
        case "speaker": return "speaker.wave.2.fill"
        default: return "hifispeaker.fill"
        }
    }

    private func spotifyDeviceMenuTitle(_ device: SpotifyDesktopDevice) -> String {
        let duplicateNames = Dictionary(grouping: store.spotifyDesktopDevices, by: \.name)
        guard (duplicateNames[device.name]?.count ?? 0) > 1 else { return device.name }
        return "\(device.name) • \(spotifyDeviceQualifier(device))"
    }

    /// Short disambiguator for devices that share a name: a Cast/Chromecast
    /// endpoint vs. the device's own native Spotify app.
    private func spotifyDeviceQualifier(_ device: SpotifyDesktopDevice) -> String {
        device.deviceType.localizedCaseInsensitiveContains("cast") ? "Cast" : "Spotify App"
    }

    // MARK: - Helpers

    private func updateDisclosureState(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

// MARK: - Spotify mark

private struct SpotifyMarkView: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(
                x: (proxy.size.width - size) / 2,
                y: (proxy.size.height - size) / 2,
                width: size,
                height: size
            )

            ZStack {
                Circle()
                    .stroke(.primary, lineWidth: max(1.2, size * 0.08))
                    .frame(width: size * 0.86, height: size * 0.86)

                spotifyWave(in: rect, y: 0.40, width: 0.50)
                    .stroke(.primary, style: StrokeStyle(lineWidth: max(1.2, size * 0.075), lineCap: .round))

                spotifyWave(in: rect, y: 0.54, width: 0.42)
                    .stroke(.primary, style: StrokeStyle(lineWidth: max(1.1, size * 0.065), lineCap: .round))

                spotifyWave(in: rect, y: 0.67, width: 0.33)
                    .stroke(.primary, style: StrokeStyle(lineWidth: max(1.0, size * 0.055), lineCap: .round))
            }
        }
        .padding(1)
    }

    private func spotifyWave(in rect: CGRect, y: CGFloat, width: CGFloat) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.midX - rect.width * width / 2, y: rect.minY + rect.height * y)
        let end = CGPoint(x: rect.midX + rect.width * width / 2, y: rect.minY + rect.height * (y + 0.05))
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: rect.midX - rect.width * width * 0.15, y: rect.minY + rect.height * (y - 0.06)),
            control2: CGPoint(x: rect.midX + rect.width * width * 0.20, y: rect.minY + rect.height * (y - 0.02))
        )
        return path
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
