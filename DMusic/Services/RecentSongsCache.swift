import Foundation
import Observation

nonisolated struct RecentEntry: Codable, Sendable {
    let song: Song
    let fileName: String
    var lastPlayed: Date
    let size: Int64
}

/// Guarda em disco o arquivo das músicas tocadas recentemente (limite em MB, remoção LRU).
/// Músicas em cache tocam localmente, sem gastar rede. Separado dos downloads permanentes.
@Observable
@MainActor
final class RecentSongsCache {
    private(set) var entries: [RecentEntry] = []
    private(set) var inProgress: Set<String> = []
    var client: SubsonicClient?
    @ObservationIgnored var settings: CacheSettings?
    @ObservationIgnored var analysisStore: TrackAnalysisStore?
    @ObservationIgnored private var inFlightTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var index: URL { dir.appendingPathComponent("index.json") }

    var usedBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    /// Mais recentes primeiro.
    var songs: [Song] { entries.sorted { $0.lastPlayed > $1.lastPlayed }.map(\.song) }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("RecentSongs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let list = try? JSONDecoder().decode([RecentEntry].self, from: data) {
            entries = list.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
        }
    }

    func localURL(for id: String) -> URL? {
        entries.first { $0.song.id == id }.map { dir.appendingPathComponent($0.fileName) }
    }

    func touch(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.song.id == id }) else { return }
        entries[i].lastPlayed = Date()
        save()
    }

    /// Baixa a música em segundo plano para o cache (se habilitado). `protecting` = ids que não podem ser removidos agora.
    /// Quando `forceForAutomix` é `true`, baixa mesmo em conexão marcada como `isExpensive` (ex.: Tailscale/VPN/Celular) para garantir que a próxima música esteja 100% pronta e analisada localmente antes do mix.
    /// Se outro fluxo (ex.: lookahead) já iniciou o download desta faixa, aguarda o mesmo `Task` terminar em vez de retornar cedo sem arquivo local!
    func cache(_ song: Song, protecting: Set<String>, forceForAutomix: Bool = false) async {
        if localURL(for: song.id) != nil { return }
        if let existing = inFlightTasks[song.id] {
            await existing.value
            return
        }
        let limit = settings?.recentLimitMB ?? 1000
        if !forceForAutomix, settings?.cacheOnlyWifi == true, NetworkMonitor.shared.isExpensive { return }
        let effectiveLimit = max(limit, forceForAutomix ? 500 : 0)
        guard effectiveLimit > 0, let client,
              let url = client.makeURL("download", ["id": song.id]) else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, resp.mimeType?.contains("json") != true else { return }
                let ext = Self.resolveAudioExtension(songSuffix: song.suffix, response: resp)
                let safeId = song.id.replacingOccurrences(of: "/", with: "_")
                let name = "\(safeId).\(ext)"
                let dest = self.dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                if self.localURL(for: song.id) == nil {
                    self.entries.append(RecentEntry(song: song, fileName: name, lastPlayed: Date(), size: size))
                }
                self.trim(protecting: protecting.union([song.id]))
                self.save()
                self.analysisStore?.analyzeIfNeeded(songId: song.id, localURL: dest)
            } catch {}
        }

        inFlightTasks[song.id] = task
        inProgress.insert(song.id)
        defer {
            inFlightTasks.removeValue(forKey: song.id)
            inProgress.remove(song.id)
        }
        await task.value
    }

    func trim(protecting: Set<String> = []) {
        let limit = Int64(settings?.recentLimitMB ?? 0) * 1024 * 1024
        var total = usedBytes
        for e in entries.sorted(by: { $0.lastPlayed < $1.lastPlayed }) where total > limit && !protecting.contains(e.song.id) {
            remove(e)
            total -= e.size
        }
        save()
    }

    func clear(protecting: Set<String> = []) {
        for e in entries where !protecting.contains(e.song.id) { remove(e) }
        save()
    }

    private func remove(_ e: RecentEntry) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.fileName))
        entries.removeAll { $0.song.id == e.song.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: index, options: .atomic) }
    }

    func analyzeExistingFiles() {
        guard let analysisStore else { return }
        for e in entries {
            analysisStore.analyzeIfNeeded(songId: e.song.id, localURL: dir.appendingPathComponent(e.fileName))
        }
    }

    static func resolveAudioExtension(songSuffix: String?, response: URLResponse) -> String {
        if let s = songSuffix?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty {
            return s
        }
        if let suggested = response.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        let mime = (response.mimeType ?? "").lowercased()
        if mime.contains("flac") { return "flac" }
        if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { return "m4a" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("ogg") { return "ogg" }
        if mime.contains("opus") { return "opus" }
        return "mp3"
    }
}
