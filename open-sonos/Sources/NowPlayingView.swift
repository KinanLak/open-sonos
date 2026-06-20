import SwiftUI

struct NowPlayingView: View {
    let store: SonosStore
    var onInteraction: () -> Void = {}
    var onHoverChanged: ((Bool) -> Void) = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let group = store.selectedGroup {
                HStack(spacing: 12) {
                    albumArt(group: group)

                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(group.track?.title ?? "Nothing playing")
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)

                                if group.isPlaying {
                                    AnimatedWaveformView.small(
                                        isAnimating: true,
                                        color: .secondary,
                                        bpm: store.currentBPM
                                    )
                                }
                            }

                            Text(group.nowPlayingSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 0) {
                            hudButton(systemName: "backward.fill", size: 11) {
                                store.previousTrackButtonTapped()
                                onInteraction()
                            }
                            hudButton(systemName: group.playbackState.symbolName, size: 15, weight: .semibold) {
                                store.togglePlaybackButtonTapped()
                                onInteraction()
                            }
                            hudButton(systemName: "forward.fill", size: 11) {
                                store.nextTrackButtonTapped()
                                onInteraction()
                            }

                            Spacer(minLength: 4)

                            speakerBadge(group: group)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                volumeBar(group: group)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                emptyState
            }
        }
        .frame(width: 300)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.arrow.push() }
            else { NSCursor.pop() }
            onHoverChanged(hovering)
        }
    }

    // MARK: - Buttons

    private func hudButton(
        systemName: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDButtonStyle())
    }

    // MARK: - Speaker badge (inline)

    private func speakerBadge(group: SonosGroupModel) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 8))
            Text(group.name)
                .font(.system(size: 10))
                .lineLimit(1)
            if group.players.count > 1 {
                Text("+\(group.players.count - 1)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Volume bar

    private func volumeBar(group: SonosGroupModel) -> some View {
        HStack(spacing: 6) {
            Button {
                store.toggleMuteButtonTapped()
                onInteraction()
            } label: {
                Image(systemName: group.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(group.isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDButtonStyle())

            SonosSlider(
                value: Binding(
                    get: { Double(store.selectedGroup?.volume ?? 0) },
                    set: {
                        store.setSelectedVolumeFromUI($0)
                        onInteraction()
                    }
                ),
                disabled: group.volumeIsFixed,
                height: 4
            )
            .animation(.easeOut(duration: 0.15), value: store.selectedGroup?.volume)

            Text("\(group.volume)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: group.volume)
        }
    }

    // MARK: - Album Art

    @ViewBuilder
    private func albumArt(group: SonosGroupModel) -> some View {
        Group {
            if let url = group.track?.albumArtURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        albumArtPlaceholder
                    default:
                        albumArtPlaceholder
                    }
                }
            } else {
                albumArtPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var albumArtPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "speaker.slash")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No speakers found")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - HUD Button Style

struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.001))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
