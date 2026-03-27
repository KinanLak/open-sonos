import SwiftUI

@main
struct OpenSonosApp: App {
    @State private var store = SonosStore()

    var body: some Scene {
        MenuBarExtra {
            SonosMenuView(store: store)
                .task {
                    await store.startIfNeeded()
                }
        } label: {
            Label(store.menuBarTitle, systemImage: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
