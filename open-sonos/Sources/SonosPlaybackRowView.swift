import SwiftUI

struct SonosPlaybackRowView: View {
    let store: SonosStore
    let group: SonosGroupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.name)
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.track?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                Text(group.nowPlayingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button {
                    store.previousTrackButtonTapped()
                } label: {
                    Image(systemName: "backward.fill")
                }

                Button {
                    store.togglePlaybackButtonTapped()
                } label: {
                    Image(systemName: group.playbackState.symbolName)
                }

                Button {
                    store.nextTrackButtonTapped()
                } label: {
                    Image(systemName: "forward.fill")
                }

                Spacer()

                Button {
                    store.toggleMuteButtonTapped()
                } label: {
                    Image(systemName: group.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
