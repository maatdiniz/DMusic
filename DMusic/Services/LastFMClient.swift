import Foundation

nonisolated enum LastFMError: LocalizedError {
    case network(String)
    case api(code: Int, message: String)
    case badResponse
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Sem conexão com o Last.fm. \(m)"
        case .api(let code, let message):
            if code == 4 { return "Usuário ou senha do Last.fm incorretos." }
            if code == 10 { return "API Key inválida." }
            if code == 13 { return "Shared Secret inválido (assinatura rejeitada)." }
            return "Last.fm (\(code)): \(message)"
        case .badResponse: return "Resposta inesperada do Last.fm."
        case .notConfigured: return "Last.fm não configurado."
        }
    }

    /// Erros temporários: mantém na fila e tenta de novo depois.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .api(let code, _): return [8, 11, 16, 29].contains(code)
        default: return false
        }
    }

    /// Sessão inválida/revogada: precisa reconectar.
    var isAuthFailure: Bool {
        if case .api(let code, _) = self { return [4, 9, 14, 15, 26].contains(code) }
        return false
    }
}

/// Cliente mínimo da Last.fm API 2.0 (https://www.last.fm/api/scrobbling), sem dependências.
nonisolated struct LastFMClient: Sendable {
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    let apiKey: String
    let secret: String
    var sessionKey: String?

    struct Track: Sendable {
        let artist: String
        let title: String
        let album: String?
        let albumArtist: String?
        let trackNumber: Int?
        let duration: Int?
        let timestamp: Int
    }

    private struct Response: Decodable {
        struct Session: Decodable { let name: String; let key: String }
        let error: Int?
        let message: String?
        let session: Session?
    }

    /// api_sig = md5( parâmetros ordenados como nome+valor, sem `format`, + secret )
    static func signature(_ params: [String: String], secret: String) -> String {
        let base = params.filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return SubsonicClient.md5(base)
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    @discardableResult
    private func call(_ method: String, _ extra: [String: String]) async throws -> Response {
        var params = extra
        params["method"] = method
        params["api_key"] = apiKey
        if let sessionKey { params["sk"] = sessionKey }
        params["api_sig"] = Self.signature(params, secret: secret)
        params["format"] = "json"

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .sorted { $0.key < $1.key }
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw LastFMError.network(error.localizedDescription) }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw LastFMError.badResponse }
        if let code = r.error { throw LastFMError.api(code: code, message: r.message ?? "") }
        return r
    }

    /// Autenticação mobile (usuário + senha). A senha não é guardada; só o session key.
    func mobileSession(username: String, password: String) async throws -> (name: String, key: String) {
        let r = try await call("auth.getMobileSession", ["username": username, "password": password])
        guard let s = r.session else { throw LastFMError.badResponse }
        return (s.name, s.key)
    }

    func updateNowPlaying(_ t: Track) async throws {
        var p = ["artist": t.artist, "track": t.title]
        if let a = t.album, !a.isEmpty { p["album"] = a }
        if let aa = t.albumArtist, !aa.isEmpty { p["albumArtist"] = aa }
        if let tn = t.trackNumber, tn > 0 { p["trackNumber"] = String(tn) }
        if let d = t.duration, d > 0 { p["duration"] = String(d) }
        try await call("track.updateNowPlaying", p)
    }

    /// Envia até 50 scrobbles por requisição.
    func scrobble(_ tracks: [Track]) async throws {
        guard !tracks.isEmpty else { return }
        var p: [String: String] = [:]
        for (i, t) in tracks.prefix(50).enumerated() {
            p["artist[\(i)]"] = t.artist
            p["track[\(i)]"] = t.title
            p["timestamp[\(i)]"] = String(t.timestamp)
            if let a = t.album, !a.isEmpty { p["album[\(i)]"] = a }
            if let aa = t.albumArtist, !aa.isEmpty { p["albumArtist[\(i)]"] = aa }
            if let tn = t.trackNumber, tn > 0 { p["trackNumber[\(i)]"] = String(tn) }
            if let d = t.duration, d > 0 { p["duration[\(i)]"] = String(d) }
        }
        try await call("track.scrobble", p)
    }
}
