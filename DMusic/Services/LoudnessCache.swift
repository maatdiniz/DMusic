import Foundation

/// Loudness (LUFS) e pico de cada faixa, guardados em `Caches/loudness.json`.
/// Medir exige decodificar ~40 s de áudio; com este cache cada faixa é medida uma única vez na vida do app
/// (antes o cache vivia só na memória e tudo era medido de novo a cada abertura).
/// Thread-safe: usado pelo motor de áudio e pelo caminho de reprodução sem mix.
final class LoudnessCache: @unchecked Sendable {
    static let shared = LoudnessCache()

    struct Entry: Codable, Sendable {
        var lufs: Float
        var peakDB: Float
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var saveScheduled = false
    private let url: URL
    private let queue = DispatchQueue(label: "dmusic.loudness-cache", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("loudness.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func get(_ songId: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[songId]
    }

    func set(_ songId: String, lufs: Float, peakDB: Float) {
        lock.lock()
        entries[songId] = Entry(lufs: lufs, peakDB: peakDB)
        let needsSchedule = !saveScheduled
        saveScheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        // Agrupa gravações: no máximo uma a cada 3 s
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.entries
            self.saveScheduled = false
            self.lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: self.url, options: .atomic) }
        }
    }
}
