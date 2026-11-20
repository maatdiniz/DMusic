import Foundation
import Observation

enum LibrarySection: String, CaseIterable, Identifiable {
    case albums = "Álbuns", artists = "Artistas", songs = "Músicas", playlists = "Playlists"
    case favorites = "Favoritas", downloads = "Baixadas"
    var id: String { rawValue }
}

@Observable
@MainActor
final class LibraryViewModel {
    var section: LibrarySection = .albums
    var albums: [Album] = []
    var artists: [Artist] = []
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var isLoading = false
    var errorMessage: String?
    private(set) var songsEnd = false
    private let pageSize = 300
    var hasLoadedAllSongs: Bool { songsEnd }

    func load(client: SubsonicClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch section {
            case .albums:
                if albums.isEmpty { albums = try await client.albumList(type: "alphabeticalByName", size: 500) }
            case .artists:
                if artists.isEmpty { artists = try await client.artists() }
            case .songs:
                if songs.isEmpty { try await loadMoreSongs(client: client) }
            case .playlists:
                playlists = try await client.playlists()
            case .favorites, .downloads:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Paginação da lista completa de músicas.
    func loadMoreSongs(client: SubsonicClient) async throws {
        guard !songsEnd else { return }
        let page = try await client.songs(offset: songs.count, count: pageSize)
        if page.count < pageSize { songsEnd = true }
        let known = Set(songs.map(\.id))
        songs += page.filter { !known.contains($0.id) }
    }

    func loadMoreIfNeeded(current song: Song, client: SubsonicClient) async {
        guard let idx = songs.firstIndex(where: { $0.id == song.id }), idx >= songs.count - 30 else { return }
        try? await loadMoreSongs(client: client)
    }

    /// Carrega TODAS as músicas da biblioteca paginando até o fim, para o Smart Shuffle e Play All enxergarem os 740+ títulos.
    func loadAllSongs(client: SubsonicClient) async -> [Song] {
        var safetyPages = 0
        while !songsEnd && safetyPages < 40 {
            safetyPages += 1
            guard let page = try? await client.songs(offset: songs.count, count: 500) else { break }
            if page.isEmpty {
                songsEnd = true
                break
            }
            let known = Set(songs.map(\.id))
            let added = page.filter { !known.contains($0.id) }
            if added.isEmpty {
                songsEnd = true
                break
            }
            songs += added
        }
        return songs
    }

    func refreshPlaylists(client: SubsonicClient) async {
        playlists = (try? await client.playlists()) ?? playlists
    }
}
