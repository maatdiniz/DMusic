import Foundation
import CryptoKit

nonisolated enum SubsonicError: LocalizedError {
    case invalidURL
    case network(String)
    case server(code: Int?, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL do servidor inválida."
        case .network(let m): return "Não foi possível conectar ao servidor. \(m)"
        case .server(let code, let message):
            if code == 40 || code == 41 { return "Usuário ou senha incorretos." }
            return message
        case .badResponse: return "Resposta inesperada do servidor."
        }
    }
}

nonisolated struct SubsonicClient: Sendable {
    let serverURL: String
    let username: String
    let password: String

    static let apiVersion = "1.16.1"
    static let clientName = "iOSHiResPlayer"

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: URL / Auth

    static func randomSalt(length: Int = 12) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<max(length, 6)).map { _ in chars.randomElement()! })
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Monta URL com autenticação por token (novo salt a cada chamada).
    func makeURL(_ endpoint: String, _ params: [String: String] = [:], multi: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: serverURL + "/rest/\(endpoint).view") else { return nil }
        let salt = Self.randomSalt()
        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: Self.md5(password + salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items += params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += multi
        comps.queryItems = items
        return comps.url
    }

    /// `maxBitRate` nil = arquivo original (bit-perfect). Com valor, o servidor transcodifica para MP3.
    func streamURL(for songId: String, maxBitRate: Int? = nil) -> URL? {
        if let maxBitRate { return makeURL("stream", ["id": songId, "format": "mp3", "maxBitRate": String(maxBitRate)]) }
        return makeURL("stream", ["id": songId, "format": "raw"])
    }

    func coverArtURL(id: String, size: Int) -> URL? { makeURL("getCoverArt", ["id": id, "size": String(size)]) }

    // MARK: Requests

    private func request(_ endpoint: String, _ params: [String: String] = [:], multi: [URLQueryItem] = []) async throws -> SubsonicResponse.Body {
        guard let url = makeURL(endpoint, params, multi: multi) else { throw SubsonicError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw SubsonicError.network(error.localizedDescription)
        }
        guard let decoded = try? JSONDecoder().decode(SubsonicResponse.self, from: data) else {
            throw SubsonicError.badResponse
        }
        let body = decoded.body
        if body.status != "ok" {
            throw SubsonicError.server(code: body.error?.code, message: body.error?.message ?? "Erro desconhecido.")
        }
        return body
    }

    func ping() async throws { _ = try await request("ping") }

    func albumList(type: String, size: Int = 20, offset: Int = 0) async throws -> [Album] {
        try await request("getAlbumList2", ["type": type, "size": String(size), "offset": String(offset)])
            .albumList2?.album ?? []
    }

    func artists() async throws -> [Artist] {
        let raw = try await request("getArtists").artists?.index?.flatMap { $0.artist ?? [] } ?? []
        return ArtistParser.normalizeArtistList(raw)
    }

    func playlists() async throws -> [Playlist] {
        try await request("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(id: String) async throws -> Playlist {
        guard let p = try await request("getPlaylist", ["id": id]).playlist else { throw SubsonicError.badResponse }
        return p
    }

    func album(id: String) async throws -> Album {
        guard let a = try await request("getAlbum", ["id": id]).album else { throw SubsonicError.badResponse }
        return a
    }

    func artist(id: String) async throws -> Artist {
        guard let a = try await request("getArtist", ["id": id]).artist else { throw SubsonicError.badResponse }
        return a
    }

    func song(id: String) async throws -> Song {
        guard let s = try await request("getSong", ["id": id]).song else { throw SubsonicError.badResponse }
        return s
    }

    func search(_ query: String, artistCount: Int = 25, albumCount: Int = 50, songCount: Int = 100) async throws -> SubsonicResponse.SearchResult {
        let body = try await request("search3", [
            "query": query,
            "artistCount": String(artistCount),
            "albumCount": String(albumCount),
            "songCount": String(songCount)
        ])
        return body.searchResult3 ?? .init(artist: nil, album: nil, song: nil)
    }

    /// Retorna todos os álbuns (próprios + participações em álbuns de outros artistas) e músicas de um artista individual.
    func artistDiscography(artistId: String, name: String) async -> (albums: [Album], songs: [Song], coverArt: String?) {
        var albumsById: [String: Album] = [:]
        var albumOrder: [String] = []
        var songsById: [String: Song] = [:]
        var songOrder: [String] = []
        var coverArt: String?

        func addAlbum(_ a: Album) {
            if albumsById[a.id] == nil {
                albumOrder.append(a.id)
                albumsById[a.id] = a
            }
            if coverArt == nil, let c = a.coverArt { coverArt = c }
        }

        func addSong(_ s: Song) {
            if songsById[s.id] == nil {
                songOrder.append(s.id)
                songsById[s.id] = s
            }
        }

        var fetchedArtistIds: Set<String> = []

        if !artistId.isEmpty, !artistId.hasPrefix("name:"), let direct = try? await artist(id: artistId) {
            fetchedArtistIds.insert(artistId)
            let parts = ArtistParser.splitNames(from: direct.name)
            if parts.count == 1, let c = direct.coverArt { coverArt = c }
            for al in direct.album ?? [] {
                if parts.count == 1 || ArtistParser.albumMatchesArtist(al, artistName: name) || parts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    addAlbum(al)
                }
            }
        }

        if let sr = try? await search(name, artistCount: 30, albumCount: 100, songCount: 200) {
            for a in sr.artist ?? [] where !fetchedArtistIds.contains(a.id) {
                let parts = ArtistParser.splitNames(from: a.name)
                guard parts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                fetchedArtistIds.insert(a.id)
                if parts.count == 1, coverArt == nil { coverArt = a.coverArt }
                if let full = try? await artist(id: a.id) {
                    for al in full.album ?? [] { addAlbum(al) }
                }
            }

            for al in sr.album ?? [] where ArtistParser.albumMatchesArtist(al, artistName: name) {
                addAlbum(al)
            }

            for s in sr.song ?? [] where ArtistParser.songMatchesArtist(s, artistName: name) {
                addSong(s)
                if let aid = s.albumId, !aid.isEmpty, albumsById[aid] == nil {
                    if let fullAlb = try? await album(id: aid) {
                        addAlbum(fullAlb)
                    } else {
                        addAlbum(Album(id: aid, name: s.album, title: s.album, artist: s.artist, artistId: s.artistId, coverArt: s.coverArt, year: s.year))
                    }
                }
            }
        }

        let albums = albumOrder.compactMap { albumsById[$0] }
        let songs = songOrder.compactMap { songsById[$0] }
        return (albums, songs, coverArt)
    }

    // MARK: Todas as músicas, favoritas, playlists

    /// Navidrome retorna toda a biblioteca em search3 com query vazia (paginado).
    func songs(offset: Int, count: Int) async throws -> [Song] {
        try await request("search3", ["query": "", "artistCount": "0", "albumCount": "0",
                                      "songCount": String(count), "songOffset": String(offset)])
            .searchResult3?.song ?? []
    }

    func randomSongs(size: Int = 100) async throws -> [Song] {
        try await request("getRandomSongs", ["size": String(size)]).randomSongs?.song ?? []
    }

    func starred() async throws -> SubsonicResponse.SearchResult {
        try await request("getStarred2").starred2 ?? .init(artist: nil, album: nil, song: nil)
    }

    func star(_ songId: String, on: Bool) async throws {
        _ = try await request(on ? "star" : "unstar", ["id": songId])
    }

    func createPlaylist(name: String, songIds: [String]) async throws {
        _ = try await request("createPlaylist", ["name": name], multi: songIds.map { URLQueryItem(name: "songId", value: $0) })
    }

    func addToPlaylist(id: String, songIds: [String]) async throws {
        _ = try await request("updatePlaylist", ["playlistId": id], multi: songIds.map { URLQueryItem(name: "songIdToAdd", value: $0) })
    }

    func removeFromPlaylist(id: String, index: Int) async throws {
        _ = try await request("updatePlaylist", ["playlistId": id, "songIndexToRemove": String(index)])
    }

    func deletePlaylist(id: String) async throws { _ = try await request("deletePlaylist", ["id": id]) }

    /// `time` em milissegundos (momento real em que a faixa foi tocada) — permite scrobble offline retroativo.
    func scrobble(songId: String, time: Int? = nil) async throws {
        var p = ["id": songId, "submission": "true"]
        if let time { p["time"] = String(time) }
        _ = try await request("scrobble", p)
    }
}
