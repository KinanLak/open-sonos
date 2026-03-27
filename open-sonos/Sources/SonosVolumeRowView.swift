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
            .disabled(group.volumeIsFixed)

            HStack {
                Button("-5") {
                    store.stepSelectedVolume(-5)
                }
                .disabled(group.volumeIsFixed)

                Button("+5") {
                    store.stepSelectedVolume(5)
                }
                .disabled(group.volumeIsFixed)

                Spacer()

                Text(group.volumeIsFixed ? "Fixed volume" : group.playerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
    }
}
