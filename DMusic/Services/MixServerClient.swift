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

    /// Grade de batidas oficial da faixa (a mesma que o servidor usa para decidir e o app para mixar).
    func fetchTrackGrid(id: String) async throws -> ServerTrackGrid {
        guard let url = URL(string: "\(baseURL)/api/track/\(id)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ServerTrackGrid.self, from: data)
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

nonisolated struct ServerTrackGrid: Codable, Sendable {
    let bpm: Double
    let beats: [Double]
    let downbeats: [Double]
}

/// Cache das grades do servidor (memória + `Caches/grids/<id>.json`, válido por 6 h).
actor TrackGridCache {
    static let shared = TrackGridCache()
    private var memory: [String: ServerTrackGrid] = [:]
    private let dir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("grids", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func grid(for songId: String, client: MixServerClient?) async -> ServerTrackGrid? {
        if let hit = memory[songId] { return hit }
        let safe = String(songId.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        let file = dir.appendingPathComponent("\(safe).json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 6 * 3600,
           let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode(ServerTrackGrid.self, from: data) {
            memory[songId] = cached
            return cached
        }
        guard let client, let fresh = try? await client.fetchTrackGrid(id: songId), !fresh.beats.isEmpty else { return nil }
        memory[songId] = fresh
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: file, options: .atomic) }
        return fresh
    }
}
