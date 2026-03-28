import SwiftUI

@main
struct OpenSonosApp: App {
    @NSApplicationDelegateAdaptor(OpenSonosAppDelegate.self) private var appDelegate
    @State private var store = SonosStore()

    var body: some Scene {
        MenuBarExtra {
            SonosMenuView(store: store)
                .task {
                    appDelegate.openURLHandler = { url in
                        Task {
                            await store.handleIncomingURL(url)
                        }
                    }
                    await store.startIfNeeded()
                }
        } label: {
            Label(store.menuBarTitle, systemImage: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("OpenSonos Settings", id: "settings") {
            SonosSettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
