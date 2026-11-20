import Foundation

nonisolated struct MixServerClient: Sendable {
    let baseURL: String

    /// Deriva a URL do DMusic Mix Server a partir da URL do Navidrome (porta 4534) ou usa override salvo.
    static func defaultURL(fromNavidrome navidromeURL: String) -> String {
        if let custom = UserDefaults.standard.string(forKey: "mix_server_url"),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SubsonicClient.normalize(custom)
        }
        let normalized = SubsonicClient.normalize(navidromeURL)
        guard var comps = URLComponents(string: normalized) else { return normalized }
        comps.port = 4534
        comps.path = ""
        return comps.string ?? normalized
    }

    func health() async throws -> MixServerHealth {
        guard let url = URL(string: "\(baseURL)/api/health") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(MixServerHealth.self, from: data)
    }

    func fetchAllTracks() async throws -> [ServerTrackMixInfo] {
        guard let url = URL(string: "\(baseURL)/api/tracks") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(MixServerTracksResponse.self, from: data).tracks
    }

    func fetchTransition(from idA: String, to idB: String, barsOverride: Int? = nil) async throws -> TransitionPlan {
        guard var comps = URLComponents(string: "\(baseURL)/api/transition") else { throw URLError(.badURL) }
        var items = [
            URLQueryItem(name: "from", value: idA),
            URLQueryItem(name: "to", value: idB)
        ]
        if let barsOverride, barsOverride > 0 {
            items.append(URLQueryItem(name: "bars", value: String(barsOverride)))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TransitionPlan.self, from: data)
    }

    func triggerScan() async throws {
        guard let url = URL(string: "\(baseURL)/api/scan") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
