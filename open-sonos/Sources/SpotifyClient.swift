import Foundation

// MARK: - BPM client using Deezer API (free, no auth required)

actor BPMClient {
    private let session = URLSession.shared

    /// Search for a track on Deezer and return its BPM.
    /// Two calls: search → track detail (which contains BPM).
    func searchBPM(title: String, artist: String? = nil) async throws -> Double? {
        let cleanTitle = Self.cleanTitle(title)
        let cleanArtist = artist?.nilIfBlank.flatMap { Self.cleanArtist($0) }

        // Build Deezer search query
        var query = "track:\"\(cleanTitle)\""
        if let cleanArtist {
            query += " artist:\"\(cleanArtist)\""
        }

        // 1. Search for the track
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "1"),
        ]

        guard let searchURL = components.url else { return nil }

        let (searchData, searchResponse) = try await session.data(for: URLRequest(url: searchURL))
        guard (searchResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let searchResult = try JSONDecoder().decode(DeezerSearchResponse.self, from: searchData)
        guard let trackID = searchResult.data?.first?.id else { return nil }

        // 2. Fetch track detail (contains BPM)
        let trackURL = URL(string: "https://api.deezer.com/track/\(trackID)")!
        let (trackData, trackResponse) = try await session.data(for: URLRequest(url: trackURL))
        guard (trackResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let track = try JSONDecoder().decode(DeezerTrack.self, from: trackData)
        guard let bpm = track.bpm, bpm > 0 else { return nil }
        return bpm
    }

    // MARK: - Title/Artist cleanup

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw

        let featPatterns = [" feat.", " feat ", " ft.", " ft ", " featuring "]
        for pattern in featPatterns {
            if let range = s.range(of: pattern, options: .caseInsensitive) {
                s = String(s[..<range.lowerBound])
            }
        }

        s = s.replacingOccurrences(of: "\\s*[\\(\\[].*?[\\)\\]]", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".-")))

        return s
    }

    private static func cleanArtist(_ raw: String) -> String {
        let separators = [",", " & ", " and ", " x "]
        var s = raw
        for sep in separators {
            if let range = s.range(of: sep, options: .caseInsensitive) {
                s = String(s[..<range.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Deezer response models

private struct DeezerSearchResponse: Decodable {
    var data: [DeezerSearchItem]?
}

private struct DeezerSearchItem: Decodable {
    var id: Int
}

private struct DeezerTrack: Decodable {
    var bpm: Double?
}

// MARK: - Spotify ID extraction from Sonos track URI

enum SpotifyIDParser {
    static func extractTrackID(from uri: String) -> String? {
        let decoded = uri.removingPercentEncoding ?? uri
        guard let range = decoded.range(of: "spotify:track:", options: .caseInsensitive) else { return nil }
        let afterPrefix = decoded[range.upperBound...]
        let id = afterPrefix.prefix(while: { $0.isLetter || $0.isNumber })
        return id.isEmpty ? nil : String(id)
    }
}
