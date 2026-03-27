import Foundation

enum SonosNetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case badStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Sonos URL."
        case .invalidResponse:
            return "Unexpected response from the Sonos speaker."
        case .badStatusCode(let statusCode):
            return "The Sonos speaker returned HTTP \(statusCode)."
        }
    }
}

actor SonosSOAPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        self.session = URLSession(configuration: configuration)
    }

    func fetchText(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return String(decoding: data, as: UTF8.self)
    }

    func sendAction(baseURL: URL, path: String, serviceType: String, action: String, body: String) async throws -> String {
        guard let requestURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw SonosNetworkError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope(for: body).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return String(decoding: data, as: UTF8.self)
    }

    private func envelope(for body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            \(body)
          </s:Body>
        </s:Envelope>
        """
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonosNetworkError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SonosNetworkError.badStatusCode(httpResponse.statusCode)
        }
    }
}
