import AppKit

@MainActor
final class OpenSonosAppDelegate: NSObject, NSApplicationDelegate {
    let store = SonosStore()
    let hotkeyManager = HotkeyManager()
    let nowPlayingController = NowPlayingPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        nowPlayingController.store = store

        hotkeyManager.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .playPause: self.store.togglePlaybackButtonTapped()
            case .nextTrack: self.store.nextTrackButtonTapped()
            case .previousTrack: self.store.previousTrackButtonTapped()
            case .volumeUp: self.store.stepSelectedVolume(5)
            case .volumeDown: self.store.stepSelectedVolume(-5)
            case .toggleMute: self.store.toggleMuteButtonTapped()
            }
            self.nowPlayingController.show()
        }

        // Bootstrap at launch — not from the menu's lazy `.task`, which only runs
        // the first time the popover is opened.
        Task { await store.startIfNeeded() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { await store.handleIncomingURL(url) }
        }
    }
}
