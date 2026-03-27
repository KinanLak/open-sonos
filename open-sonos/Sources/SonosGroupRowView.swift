import SwiftUI

struct SonosGroupRowView: View {
    let group: SonosGroupModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(group.track?.title ?? group.playerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(group.volume)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: group.isPlaying ? "waveform" : "speaker.2")
                        .foregroundStyle(group.isPlaying ? Color.accentColor : Color.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
