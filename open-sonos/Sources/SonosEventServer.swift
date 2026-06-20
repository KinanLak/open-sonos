import Darwin
import Foundation
import Network

enum SonosEventServerError: LocalizedError {
    case noPort
    case noLocalAddress

    var errorDescription: String? {
        switch self {
        case .noPort:
            return "The local event server could not acquire a port."
        case .noLocalAddress:
            return "No reachable local IPv4 address was found for UPnP callbacks."
        }
    }
}

/// A minimal embedded HTTP server that listens for UPnP GENA `NOTIFY` callbacks
/// pushed by Sonos speakers. Sonos opens a TCP connection to our `CALLBACK`
/// address whenever a subscribed service's state changes, POSTing an event body.
///
/// The server parses just enough HTTP to extract the `SID` header and the body,
/// then replies `200 OK`. Parsed notifications are delivered via `onNotify`.
final class SonosEventServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kinan.opensonos.eventserver")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private(set) var port: UInt16?

    /// Invoked on an internal queue for each fully-received NOTIFY request.
    var onNotify: (@Sendable (_ sid: String, _ body: String) -> Void)?

    func start() async throws -> UInt16 {
        if let port { return port }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    if let continuation = self.startContinuation {
                        self.startContinuation = nil
                        if let resolvedPort = self.port {
                            continuation.resume(returning: resolvedPort)
                        } else {
                            continuation.resume(throwing: SonosEventServerError.noPort)
                        }
                    }
                case .failed(let error):
                    if let continuation = self.startContinuation {
                        self.startContinuation = nil
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let parsed = Self.parseRequest(accumulated) {
                if let sid = parsed.sid, !parsed.body.isEmpty {
                    self.onNotify?(sid, parsed.body)
                }
                self.respondAndClose(connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(connection, buffer: accumulated)
        }
    }

    private func respondAndClose(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    private static func parseRequest(_ data: Data) -> (sid: String?, body: String)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = data.subdata(in: data.startIndex ..< separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var headers: [String: String] = [:]
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyData = data.subdata(in: separator.upperBound ..< data.endIndex)
        guard bodyData.count >= contentLength else { return nil }

        let body = String(decoding: bodyData.prefix(contentLength), as: UTF8.self)
        return (headers["sid"], body)
    }
}

/// Resolves a LAN IPv4 address that Sonos speakers can connect back to for callbacks.
enum LocalNetworkInterface {
    static func primaryIPv4Address() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0 else { return nil }
        defer { freeifaddrs(interfacePointer) }

        var preferred: String?
        var fallback: String?

        var cursor = interfacePointer
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)

            // Prefer the primary Wi-Fi / Ethernet interface; fall back to any other.
            if name == "en0" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }

        return preferred ?? fallback
    }
}
