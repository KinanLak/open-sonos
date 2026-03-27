import SwiftUI

struct SonosMenuView: View {
    let store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let selectedGroup = store.selectedGroup {
                SonosPlaybackRowView(store: store, group: selectedGroup)
                SonosVolumeRowView(store: store, group: selectedGroup)
            }

            groupSection

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
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenSonos")
                    .font(.headline)

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let updatedAt = store.lastUpdatedAt {
                    Text(updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if store.isRefreshing || store.isPerformingAction {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Rooms")
                .font(.subheadline.weight(.semibold))

            if store.groups.isEmpty {
                Text("No Sonos speakers found yet. Make sure your Mac is on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.groups) { group in
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
}
