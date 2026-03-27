import AppKit

final class OpenSonosAppDelegate: NSObject, NSApplicationDelegate {
    var openURLHandler: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openURLHandler?(url)
        }
    }
}
