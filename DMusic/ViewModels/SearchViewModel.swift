import Foundation
import Observation

@Observable
@MainActor
final class SearchViewModel {
    var query = ""
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var isLoading = false
    var errorMessage: String?

    var hasResults: Bool { !(artists.isEmpty && albums.isEmpty && songs.isEmpty) }

    func search(client: SubsonicClient) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { artists = []; albums = []; songs = []; errorMessage = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(350)) // debounce (a task é cancelada ao digitar)
            isLoading = true
            defer { isLoading = false }
            let r = try await client.search(q)
            let rawSongs = r.song ?? []
            songs = rawSongs

            // Sempre separa artistas compostos em artistas individuais
            var rawArtists = r.artist ?? []
            for s in rawSongs {
                for entry in ArtistParser.artists(for: s) where entry.name.localizedCaseInsensitiveContains(q) {
                    rawArtists.append(Artist(id: entry.id, name: entry.name, coverArt: entry.coverArt))
                }
            }
            let normalizedArtists = ArtistParser.normalizeArtistList(rawArtists)
            let filteredArtists = normalizedArtists.filter { $0.name.localizedCaseInsensitiveContains(q) }
            artists = filteredArtists.isEmpty ? normalizedArtists : filteredArtists

            // Inclui álbuns diretos + álbuns onde o artista buscado participa em alguma faixa
            var albumList = r.album ?? []
            var seenAlbums = Set(albumList.map(\.id))
            for s in rawSongs {
                guard let aid = s.albumId, !aid.isEmpty, !seenAlbums.contains(aid) else { continue }
                let matchesArtist = ArtistParser.artists(for: s).contains { $0.name.localizedCaseInsensitiveContains(q) }
                if matchesArtist {
                    seenAlbums.insert(aid)
                    albumList.append(Album(id: aid, name: s.album, title: s.album, artist: s.artist, artistId: s.artistId, coverArt: s.coverArt, year: s.year))
                }
            }
            albums = albumList
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }
}
