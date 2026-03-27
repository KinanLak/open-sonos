import SwiftUI

struct SonosVolumeRowView: View {
    let store: SonosStore
    let group: SonosGroupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Group volume")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(group.volume)%")
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

            HStack {
                Button("-5") {
                    store.stepSelectedVolume(-5)
                }

                Button("+5") {
                    store.stepSelectedVolume(5)
                }

                Spacer()

                Text(group.playerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
    }
}
