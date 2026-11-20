import Foundation
import Observation

/// Músicas favoritas (estrela do Subsonic: star.view / unstar.view / getStarred2).
@Observable
@MainActor
final class FavoritesStore {
    private(set) var ids: Set<String> = []
    private(set) var songs: [Song] = []
    var client: SubsonicClient?

    func isFavorite(_ id: String) -> Bool { ids.contains(id) }

    func load() async {
        guard let client, let r = try? await client.starred() else { return }
        songs = r.song ?? []
        ids = Set(songs.map(\.id))
    }

    func toggle(_ song: Song) {
        guard let client else { return }
        let on = !ids.contains(song.id)
        apply(song, on: on)
        Task {
            do { try await client.star(song.id, on: on) }
            catch { apply(song, on: !on) }   // desfaz se o servidor falhar
        }
    }

    private func apply(_ song: Song, on: Bool) {
        if on { ids.insert(song.id); if !songs.contains(where: { $0.id == song.id }) { songs.insert(song, at: 0) } }
        else { ids.remove(song.id); songs.removeAll { $0.id == song.id } }
    }
}
