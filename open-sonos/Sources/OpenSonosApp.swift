import SwiftUI

@main
struct OpenSonosApp: App {
    @NSApplicationDelegateAdaptor(OpenSonosAppDelegate.self) private var appDelegate
    @State private var store = SonosStore()
    @State private var hotkeyManager = HotkeyManager()
    @State private var nowPlayingController = NowPlayingPanelController()

    var body: some Scene {
        MenuBarExtra {
            SonosMenuView(store: store)
                .task {
                    appDelegate.openURLHandler = { url in
                        Task {
                            await store.handleIncomingURL(url)
                        }
                    }

                    nowPlayingController.store = store
                    hotkeyManager.onAction = { [weak nowPlayingController] action in
                        switch action {
                        case .playPause: store.togglePlaybackButtonTapped()
                        case .nextTrack: store.nextTrackButtonTapped()
                        case .previousTrack: store.previousTrackButtonTapped()
                        case .volumeUp: store.stepSelectedVolume(5)
                        case .volumeDown: store.stepSelectedVolume(-5)
                        case .toggleMute: store.toggleMuteButtonTapped()
                        }
                        nowPlayingController?.show()
                    }

                    await store.startIfNeeded()
                }
        } label: {
            Label(store.menuBarTitle, systemImage: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("OpenSonos Settings", id: "settings") {
            SonosSettingsView(store: store, hotkeyManager: hotkeyManager)
        }
        .windowResizability(.contentSize)
    }
}
