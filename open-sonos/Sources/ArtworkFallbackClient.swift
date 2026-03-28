import Foundation

actor ArtworkFallbackClient {
    static let shared = ArtworkFallbackClient()

    private var cache: [String: URL] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]
    private let maxCacheSize = 200

    func artworkURL(artist: String?, album: String?, title: String?) async -> URL? {
        let searchTerm = buildSearchTerm(artist: artist, album: album, title: title)
        guard let searchTerm else { return nil }

        let cacheKey = searchTerm.lowercased()
        if let cached = cache[cacheKey] {
            return cached
        }

        if let existing = pending[cacheKey] {
            return await existing.value
        }

        let task = Task<URL?, Never> {
            await fetchFromiTunes(term: searchTerm)
        }
        pending[cacheKey] = task
        let result = await task.value
        pending[cacheKey] = nil

        if let result {
            if cache.count >= maxCacheSize {
                cache.removeAll()
            }
            cache[cacheKey] = result
        }

        return result
    }

    private func buildSearchTerm(artist: String?, album: String?, title: String?) -> String? {
        let parts = [artist, album ?? title].compactMap { $0?.nilIfBlank }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private func fetchFromiTunes(term: String) async -> URL? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return parseArtworkURL(from: data)
        } catch {
            return nil
        }
    }

    private func parseArtworkURL(from data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkString = first["artworkUrl100"] as? String else {
            return nil
        }

        // Upgrade to 600x600 for better quality
        let highRes = artworkString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: highRes)
    }
}
