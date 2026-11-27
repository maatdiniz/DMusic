import Foundation

/// Ajustes de gênero feitos pelo usuário por música ou por álbum: família → forçada ligada/desligada.
/// Valem em cima da classificação automática e alimentam os modos de gênero e o Automix.
final class GenreAssignments: @unchecked Sendable {
    static let shared = GenreAssignments()

    private let key = "genre.assignments.v1"
    private let lock = NSLock()
    /// "s:<songId>" / "a:<albumId>" → [família: ligada?]
    private var map: [String: [String: Bool]]
    /// Sobe a cada mudança; quem guarda classificação em cache compara para saber se precisa refazer.
    private(set) var revision = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// Aplica álbum e depois música (a música vence) sobre as famílias detectadas.
    func apply(to detected: Set<GenreFamily>, songId: String, albumId: String?) -> Set<GenreFamily> {
        lock.lock(); defer { lock.unlock() }
        var result = detected
        for k in [albumId.map { "a:\($0)" }, "s:\(songId)"].compactMap({ $0 }) {
            guard let forced = map[k] else { continue }
            for (raw, on) in forced {
                guard let fam = GenreFamily(rawValue: raw) else { continue }
                if on { result.insert(fam) } else { result.remove(fam) }
            }
        }
        return result
    }

    /// Liga/desliga uma família para músicas soltas ou para um álbum inteiro.
    /// No álbum, os ajustes individuais dessa família nas faixas são limpos para o álbum valer para todas.
    func set(_ family: GenreFamily, enabled: Bool, songs: [Song], albumId: String?) {
        lock.lock()
        if let albumId {
            map["a:\(albumId)", default: [:]][family.rawValue] = enabled
            for s in songs { map["s:\(s.id)"]?.removeValue(forKey: family.rawValue) }
        } else {
            for s in songs { map["s:\(s.id)", default: [:]][family.rawValue] = enabled }
        }
        commitLocked()
    }

    /// Remove todos os ajustes (volta à classificação automática).
    func reset(songs: [Song], albumId: String?) {
        lock.lock()
        if let albumId { map.removeValue(forKey: "a:\(albumId)") }
        for s in songs { map.removeValue(forKey: "s:\(s.id)") }
        commitLocked()
    }

    /// Chamado com o lock tomado; solta o lock e grava.
    private func commitLocked() {
        map = map.filter { !$0.value.isEmpty }
        revision += 1
        let snapshot = map
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key) }
    }
}
