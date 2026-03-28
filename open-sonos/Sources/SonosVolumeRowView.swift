import SwiftUI

struct SonosVolumeRowView: View {
    let store: SonosStore
    let group: SonosGroupModel

    private var currentGroup: SonosGroupModel {
        store.selectedGroup ?? group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Group volume")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(currentGroup.volume)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(store.selectedGroup?.volume ?? 0) },
                    set: { store.setSelectedVolumeFromUI($0) }
                ),
                in: 0 ... 100,
                step: 1
            )
            .disabled(currentGroup.volumeIsFixed)

            HStack {
                Button("-5") {
                    store.stepSelectedVolume(-5)
                }
                .disabled(currentGroup.volumeIsFixed)

                Button("+5") {
                    store.stepSelectedVolume(5)
                }
                .disabled(currentGroup.volumeIsFixed)

                Spacer()

                Text(currentGroup.volumeIsFixed ? "Fixed volume" : currentGroup.playerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)

            if currentGroup.players.count > 1 {
                Divider()

                Text("Room volume")
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(currentGroup.players) { player in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(player.name)
                                    .font(.caption.weight(.medium))

                                if player.isCoordinator {
                                    Text("Coordinator")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(resolvedPlayerVolume(for: player.id, fallback: player.volume))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(resolvedPlayerVolume(for: player.id, fallback: player.volume)) },
                                    set: { store.setSelectedPlayerVolumeFromUI($0, playerID: player.id) }
                                ),
                                in: 0 ... 100,
                                step: 1
                            )
                            .disabled(resolvedPlayerIsFixed(for: player.id, fallback: player.volumeIsFixed))
                        }
                    }
                }
            }
        }
    }

    private func resolvedPlayerVolume(for playerID: String, fallback: Int) -> Int {
        currentGroup.players.first(where: { $0.id == playerID })?.volume ?? fallback
    }

    private func resolvedPlayerIsFixed(for playerID: String, fallback: Bool) -> Bool {
        currentGroup.players.first(where: { $0.id == playerID })?.volumeIsFixed ?? fallback
    }
}
