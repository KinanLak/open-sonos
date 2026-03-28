import SwiftUI

struct SonosPlaybackRowView: View {
    let store: SonosStore
    let group: SonosGroupModel

    var body: some View {
        HStack(spacing: 12) {
            albumArt

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.track?.title ?? "Nothing playing")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Text(group.nowPlayingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 16) {
                    Button { store.previousTrackButtonTapped() } label: {
                        Image(systemName: "backward.fill")
                            .font(.caption)
                    }

                    Button { store.togglePlaybackButtonTapped() } label: {
                        Image(systemName: group.playbackState.symbolName)
                            .font(.body.weight(.semibold))
                    }

                    Button { store.nextTrackButtonTapped() } label: {
                        Image(systemName: "forward.fill")
                            .font(.caption)
                    }

                    Spacer()

                    Button { store.toggleMuteButtonTapped() } label: {
                        Image(systemName: group.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(group.isMuted ? .red : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var albumArt: some View {
        if let url = group.track?.albumArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    albumArtPlaceholder
                default:
                    albumArtPlaceholder
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            albumArtPlaceholder
        }
    }

    private var albumArtPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
    }
}
