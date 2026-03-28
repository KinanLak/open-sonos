import SwiftUI

struct SonosGroupRowView: View {
    let group: SonosGroupModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.subheadline)

                Text(group.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if group.players.count > 1 {
                    Text("+\(group.players.count - 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if group.isPlaying, let title = group.track?.title {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 80, alignment: .trailing)
                }

                if group.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
