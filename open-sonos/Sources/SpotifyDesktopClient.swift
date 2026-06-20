import AppKit
import Foundation

actor SpotifyDesktopClient {
    private let jsonDecoder = JSONDecoder()
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func status() async throws -> SpotifyDesktopStatus {
        guard spotifyCLIURL() != nil else {
            return SpotifyDesktopStatus(helperInstalled: false, appRunning: false, isLoggedIn: false)
        }

        do {
            let data = try await runSpotifyCLI(arguments: ["status", "--format", "json"])
            let payload = try jsonDecoder.decode(SpotifyDesktopStatusPayload.self, from: data)
            return SpotifyDesktopStatus(helperInstalled: true, appRunning: payload.running, isLoggedIn: payload.loggedIn)
        } catch SpotifyDesktopError.commandFailed(let message) where message.localizedCaseInsensitiveContains("not running") {
            return SpotifyDesktopStatus(helperInstalled: true, appRunning: false, isLoggedIn: false)
        }
    }

    func listDevices() async throws -> SpotifyDesktopDevicesSnapshot {
        let data = try await runSpotifyCLI(arguments: ["devices", "list", "--format", "json"])
        return try jsonDecoder.decode(SpotifyDesktopDevicesSnapshot.self, from: data)
    }

    func transferPlayback(to deviceID: String) async throws {
        try await runSpotifyCLI(arguments: ["devices", "transfer", deviceID])
    }

    func transferPlayback(preferredNames: [String]) async throws -> SpotifyDesktopDevice {
        let snapshot = try await listDevices()
        let devices = snapshot.devices
        guard let device = Self.bestDevice(in: devices, preferredNames: preferredNames) else {
            let availableNames = devices.map(\.name).joined(separator: ", ")
            throw SpotifyDesktopError.noMatchingDevice(
                targetNames: preferredNames.joined(separator: ", "),
                availableDeviceNames: availableNames
            )
        }

        try await runSpotifyCLI(arguments: ["devices", "transfer", device.deviceID])
        return device
    }

    @discardableResult
    private func runSpotifyCLI(arguments: [String]) async throws -> Data {
        guard let executableURL = spotifyCLIURL() else { throw SpotifyDesktopError.helperNotFound }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SpotifyDesktopError.launchFailed(error.localizedDescription)
        }

        let timeout = SpotifyCLITimeout(process: process, seconds: 5)
        process.waitUntilExit()
        timeout.cancel()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if timeout.didTimeOut {
            throw SpotifyDesktopError.commandFailed("spotify_cli timed out")
        }

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput.isEmpty ? output : errorOutput, encoding: .utf8)?.nilIfBlank
            throw SpotifyDesktopError.commandFailed(message ?? "spotify_cli exited with status \(process.terminationStatus)")
        }

        return output
    }

    private func spotifyCLIURL() -> URL? {
        let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
        let candidates = [
            bundleURL?.appendingPathComponent("Contents/MacOS/spotify_cli"),
            URL(fileURLWithPath: "/Applications/Spotify.app/Contents/MacOS/spotify_cli"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spotify.app/Contents/MacOS/spotify_cli"),
        ].compactMap { $0 }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func bestDevice(in devices: [SpotifyDesktopDevice], preferredNames: [String]) -> SpotifyDesktopDevice? {
        for preferredName in preferredNames {
            let normalizedPreferred = normalizedDeviceName(preferredName)
            if let exactMatch = devices.first(where: { normalizedDeviceName($0.name) == normalizedPreferred }) {
                return exactMatch
            }
        }

        for preferredName in preferredNames {
            let normalizedPreferred = normalizedDeviceName(preferredName)
            if let partialMatch = devices.first(where: { device in
                let normalizedDevice = normalizedDeviceName(device.name)
                return normalizedDevice.contains(normalizedPreferred) || normalizedPreferred.contains(normalizedDevice)
            }) {
                return partialMatch
            }
        }

        let speakers = devices.filter { $0.deviceType.localizedCaseInsensitiveCompare("speaker") == .orderedSame }
        if speakers.count == 1 {
            return speakers[0]
        }

        return nil
    }

    private static func normalizedDeviceName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private final class SpotifyCLITimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    init(process: Process, seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self, weak process] in
            guard let self else { return }
            self.lock.lock()
            let shouldTerminate = !self.isCancelled
            if shouldTerminate { self.timedOut = true }
            self.lock.unlock()

            if shouldTerminate, process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

struct SpotifyDesktopDevice: Hashable, Decodable {
    var deviceID: String
    var name: String
    var deviceType: String
    var volume: Int?
    var isActive: Bool?
    var isGroup: Bool?
    var isLocal: Bool?
    var isSelf: Bool?
    var brand: String?
    var model: String?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case deviceType = "device_type"
        case volume
        case isActive = "is_active"
        case isGroup = "is_group"
        case isLocal = "is_local"
        case isSelf = "is_self"
        case brand
        case model
    }
}

struct SpotifyDesktopDevicesSnapshot: Hashable, Decodable {
    var activeDeviceID: String?
    var devices: [SpotifyDesktopDevice]

    private enum CodingKeys: String, CodingKey {
        case activeDeviceID = "active_device_id"
        case devices
    }
}

struct SpotifyDesktopStatus: Hashable {
    var helperInstalled: Bool
    var appRunning: Bool
    var isLoggedIn: Bool

    var isReady: Bool {
        helperInstalled && appRunning && isLoggedIn
    }
}

private struct SpotifyDesktopStatusPayload: Decodable {
    var running: Bool
    var loggedIn: Bool

    private enum CodingKeys: String, CodingKey {
        case running
        case loggedIn = "logged_in"
    }
}

enum SpotifyDesktopError: LocalizedError {
    case helperNotFound
    case launchFailed(String)
    case commandFailed(String)
    case noMatchingDevice(targetNames: String, availableDeviceNames: String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "Spotify Desktop helper was not found. Install Spotify Desktop and try again."
        case .launchFailed(let message):
            return "Spotify Desktop helper could not start: \(message)"
        case .commandFailed(let message):
            return "Spotify Desktop helper failed: \(message)"
        case .noMatchingDevice(let targetNames, let availableDeviceNames):
            if targetNames.nilIfBlank != nil, availableDeviceNames.nilIfBlank != nil {
                return "Spotify Desktop devices: \(availableDeviceNames). Sonos targets: \(targetNames)."
            }
            if availableDeviceNames.nilIfBlank != nil {
                return "Spotify Desktop devices: \(availableDeviceNames). No matching Sonos target was found."
            }
            return "Spotify Desktop did not return a matching Sonos device."
        }
    }
}
