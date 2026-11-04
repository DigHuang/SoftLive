import Foundation

enum HTTPClient {
    /// GETs and decodes JSON. Returns `nil` on 404; throws on transport or other HTTP errors.
    static func get<T: Decodable>(
        _ base: String, query: [String: String] = [:], headers: [String: String] = [:], as type: T.Type = T.self
    ) async throws -> T? {
        guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("SoftLive/0.1 (macOS lyrics overlay)", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return try JSONDecoder().decode(T.self, from: data)
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }
}
