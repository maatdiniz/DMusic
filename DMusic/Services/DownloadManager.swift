import Foundation
import Observation

nonisolated struct DownloadedSong: Codable, Sendable {
    let song: Song
    let fileName: String
}

/// Mantém músicas baixadas em Application Support/Downloads (arquivo original, sem transcodificação).
@Observable
@MainActor
final class DownloadManager {
    private(set) var entries: [DownloadedSong] = []
    private(set) var inProgress: Set<String> = []
    var errorMessage: String?
    var client: SubsonicClient?
    @ObservationIgnored var analysisStore: TrackAnalysisStore?

    var songs: [Song] { entries.map(\.song) }

    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var index: URL { dir.appendingPathComponent("index.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let list = try? JSONDecoder().decode([DownloadedSong].self, from: data) {
            entries = list.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
        }
    }

    func isDownloaded(_ id: String) -> Bool { entries.contains { $0.song.id == id } }
    func isDownloading(_ id: String) -> Bool { inProgress.contains(id) }

    func localURL(for id: String) -> URL? {
        entries.first { $0.song.id == id }.map { dir.appendingPathComponent($0.fileName) }
    }

    func download(_ song: Song) async {
        guard let client, !isDownloaded(song.id), !inProgress.contains(song.id),
              let url = client.makeURL("download", ["id": song.id]) else { return }
        inProgress.insert(song.id)
        defer { inProgress.remove(song.id) }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  resp.mimeType?.contains("json") != true else {
                throw SubsonicError.badResponse
            }
            let ext = RecentSongsCache.resolveAudioExtension(songSuffix: song.suffix, response: resp)
            let safeId = song.id.replacingOccurrences(of: "/", with: "_")
            let name = "\(safeId).\(ext)"
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            // Arquivo vazio ou todo zerado: descarta em vez de salvar um download inutilizável
            if RecentSongsCache.isCorruptAudioFile(dest) {
                try? FileManager.default.removeItem(at: dest)
                throw SubsonicError.badResponse
            }
            if let cover = song.coverArt {   // guarda as capas em disco para uso offline
                for size in [100, 300, 600] { _ = await ImageCache.shared.image(id: cover, size: size, client: client) }
            }
            entries.append(DownloadedSong(song: song, fileName: name))
            save()
            analysisStore?.analyzeIfNeeded(songId: song.id, localURL: dest)
        } catch {
            errorMessage = "Falha ao baixar “\(song.title)”: \(error.localizedDescription)"
        }
    }

    func download(_ songs: [Song]) async {
        for s in songs { await download(s) }
    }

    func remove(_ song: Song) {
        guard let e = entries.first(where: { $0.song.id == song.id }) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.fileName))
        entries.removeAll { $0.song.id == song.id }
        save()
    }

    func remove(_ songs: [Song]) { songs.forEach(remove) }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: index, options: .atomic) }
        syncProtectedCovers()
    }

    func syncProtectedCovers() {
        let ids = Set(entries.compactMap(\.song.coverArt))
        Task { await ImageCache.shared.setProtected(ids) }
    }

    func analyzeExistingFiles() {
        guard let analysisStore else { return }
        for e in entries {
            analysisStore.analyzeIfNeeded(songId: e.song.id, localURL: dir.appendingPathComponent(e.fileName))
        }
    }
}
