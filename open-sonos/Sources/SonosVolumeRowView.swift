import SwiftUI

struct SonosVolumeRowView: View {
    let store: SonosStore
    let group: SonosGroupModel

    private var currentGroup: SonosGroupModel {
        store.selectedGroup ?? group
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            SonosSlider(
                value: Binding(
                    get: { Double(store.selectedGroup?.volume ?? 0) },
                    set: { store.setSelectedVolumeFromUI($0) }
                ),
                disabled: currentGroup.volumeIsFixed
            )

            Text("\(currentGroup.volume)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
