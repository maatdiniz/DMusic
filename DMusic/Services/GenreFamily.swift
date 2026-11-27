import Foundation

/// Família de gêneros usada pelos modos de mix: agrupa as tags soltas do Navidrome ("Deep House", "Tech House"…)
/// e diz quais famílias são vizinhas (para ampliar o pool quando um modo tem poucas músicas).
nonisolated enum GenreFamily: String, CaseIterable, Identifiable, Sendable {
    case house = "House"
    case techno = "Techno"
    case trance = "Trance"
    case drumAndBass = "Drum & Bass"
    case bass = "Bass / Dubstep"
    case electronic = "Eletrônica"
    case hipHop = "Hip-Hop / Rap"
    case funkBR = "Funk / Brasil"
    case rnb = "R&B / Soul"
    case pop = "Pop"
    case rock = "Rock"
    case latin = "Latina"
    case other = "Outros"

    var id: String { rawValue }

    /// Famílias próximas, da mais para a menos próxima. Usadas para ampliar o pool de um modo.
    var neighbors: [GenreFamily] {
        switch self {
        case .house: return [.electronic, .techno, .pop]
        case .techno: return [.house, .trance, .electronic]
        case .trance: return [.techno, .electronic, .house]
        case .drumAndBass: return [.bass, .electronic]
        case .bass: return [.drumAndBass, .hipHop, .electronic]
        case .electronic: return [.house, .techno, .pop]
        case .hipHop: return [.rnb, .funkBR, .bass]
        case .funkBR: return [.hipHop, .latin, .pop]
        case .rnb: return [.hipHop, .pop]
        case .pop: return [.electronic, .rnb, .house]
        case .rock: return [.pop]
        case .latin: return [.funkBR, .pop]
        case .other: return []
        }
    }
}

/// Etiqueta de gênero de uma música: família + subgênero opcional (ex.: House / Deep House).
nonisolated struct GenreTag: Hashable, Sendable {
    let family: GenreFamily
    let sub: String?

    var label: String { sub.map { "\(family.rawValue) • \($0)" } ?? family.rawValue }
}

/// Classifica gêneros em etiquetas. Uma tag pode cair em mais de uma família (ex.: "Tech House" → House e Techno)
/// e uma música com várias tags entra em todas elas. Ajustes manuais (`GenreOverrides`) valem mais que as regras.
nonisolated enum GenreTaxonomy {
    private struct Rule {
        let keys: [String]
        let tags: [(GenreFamily, String?)]
    }

    /// Todas as regras que casarem valem; por família fica o subgênero mais específico.
    private static let rules: [Rule] = [
        Rule(keys: ["deep house"], tags: [(.house, "Deep House")]),
        Rule(keys: ["tech house", "tech-house"], tags: [(.house, "Tech House"), (.techno, nil)]),
        Rule(keys: ["progressive house", "prog house"], tags: [(.house, "Progressive House")]),
        Rule(keys: ["melodic house", "organic house"], tags: [(.house, "Melodic House")]),
        Rule(keys: ["afro house", "afro"], tags: [(.house, "Afro House")]),
        Rule(keys: ["disco"], tags: [(.house, "Nu-Disco")]),
        Rule(keys: ["garage"], tags: [(.house, "Garage")]),
        Rule(keys: ["amapiano"], tags: [(.house, "Amapiano")]),
        Rule(keys: ["house"], tags: [(.house, nil)]),
        Rule(keys: ["melodic techno"], tags: [(.techno, "Melodic Techno")]),
        Rule(keys: ["hard techno", "hard tech"], tags: [(.techno, "Hard Techno")]),
        Rule(keys: ["minimal"], tags: [(.techno, "Minimal")]),
        Rule(keys: ["industrial"], tags: [(.techno, "Industrial")]),
        Rule(keys: ["techno"], tags: [(.techno, nil)]),
        Rule(keys: ["psy", "goa"], tags: [(.trance, "Psytrance")]),
        Rule(keys: ["trance"], tags: [(.trance, nil)]),
        Rule(keys: ["liquid"], tags: [(.drumAndBass, "Liquid")]),
        Rule(keys: ["drum", "dnb", "jungle"], tags: [(.drumAndBass, nil)]),
        Rule(keys: ["dubstep", "riddim"], tags: [(.bass, "Dubstep")]),
        Rule(keys: ["trap"], tags: [(.bass, "Trap"), (.hipHop, "Trap")]),
        Rule(keys: ["bass"], tags: [(.bass, nil)]),
        Rule(keys: ["ambient", "chill", "downtempo"], tags: [(.electronic, "Chill / Ambient")]),
        Rule(keys: ["synthwave", "synth", "retrowave"], tags: [(.electronic, "Synthwave")]),
        Rule(keys: ["electr", "eletr", "edm", "idm", "breaks", "dance"], tags: [(.electronic, nil)]),
        Rule(keys: ["funk carioca", "funk"], tags: [(.funkBR, "Funk")]),
        Rule(keys: ["sertanej", "forro", "forró", "pagode", "samba", "mpb", "axe", "axé", "brasil", "brazil", "baile"], tags: [(.funkBR, nil)]),
        Rule(keys: ["hip", "rap", "drill", "boom bap"], tags: [(.hipHop, nil)]),
        Rule(keys: ["r&b", "rnb", "neo soul", "soul", "blues", "gospel"], tags: [(.rnb, nil)]),
        Rule(keys: ["reggaeton", "reggaetón"], tags: [(.latin, "Reggaeton")]),
        Rule(keys: ["latin", "salsa", "bachata", "cumbia", "tango", "bossa"], tags: [(.latin, nil)]),
        Rule(keys: ["metal", "punk", "hardcore"], tags: [(.rock, "Pesado")]),
        Rule(keys: ["indie", "alternativ"], tags: [(.rock, "Indie / Alternativo")]),
        Rule(keys: ["rock", "grunge"], tags: [(.rock, nil)]),
        Rule(keys: ["k-pop", "kpop"], tags: [(.pop, "K-Pop")]),
        Rule(keys: ["pop"], tags: [(.pop, nil)])
    ]

    /// Separadores de multi-gênero numa mesma string ("Pop; Dance"). "&" e "/" ficam de fora de propósito:
    /// "R&B" e "Drum & Bass" são nomes de gênero.
    private static let separators = CharacterSet(charactersIn: ";,|")

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Etiquetas de uma única tag de gênero (sem dividir).
    static func tags(forTag raw: String) -> Set<GenreTag> {
        let g = fold(raw)
        if g.isEmpty { return [] }
        if let forced = GenreOverrides.shared.families(for: g) {
            return Set(forced.map { GenreTag(family: $0, sub: nil) })
        }
        var best: [GenreFamily: String?] = [:]
        var consumed = false
        for rule in rules where rule.keys.contains(where: { g.contains($0) }) {
            consumed = true
            for (fam, sub) in rule.tags {
                // Subgênero específico (regra anterior, mais específica) não é sobrescrito por uma genérica
                if let current = best[fam], current != nil { continue }
                best[fam] = sub
            }
        }
        if !consumed { return [GenreTag(family: .other, sub: nil)] }
        return Set(best.map { GenreTag(family: $0.key, sub: $0.value) })
    }

    /// Etiquetas automáticas de uma música (tags do arquivo), sem os ajustes do usuário.
    static func autoTags(for song: Song) -> Set<GenreTag> {
        var raws: [String] = []
        if let g = song.genre { raws += g.components(separatedBy: separators) }
        raws += (song.genres ?? []).map(\.name)
        var out = Set<GenreTag>()
        for r in raws { out.formUnion(tags(forTag: r)) }
        // "Outros" só vale quando nenhuma outra família casou
        if out.contains(where: { $0.family != .other }) { out = out.filter { $0.family != .other } }
        return out
    }

    /// Etiquetas finais: automáticas + ajustes do usuário (por álbum e por música).
    static func tags(for song: Song) -> Set<GenreTag> {
        let auto = autoTags(for: song)
        let detected = Set(auto.map(\.family))
        let final = GenreAssignments.shared.apply(to: detected, songId: song.id, albumId: song.albumId)
        if final == detected { return auto }
        var out = auto.filter { final.contains($0.family) }
        for fam in final where !detected.contains(fam) { out.insert(GenreTag(family: fam, sub: nil)) }
        if out.contains(where: { $0.family != .other }) { out = out.filter { $0.family != .other } }
        return out
    }
}

/// Ajustes manuais: tag de gênero (normalizada) → famílias escolhidas pelo usuário. Guardado em UserDefaults.
final class GenreOverrides: @unchecked Sendable {
    static let shared = GenreOverrides()
    private let key = "genre.overrides.v1"
    private let lock = NSLock()
    private var map: [String: [String]]

    private init() {
        map = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    func families(for foldedTag: String) -> [GenreFamily]? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = map[foldedTag] else { return nil }
        return raw.compactMap(GenreFamily.init(rawValue:))
    }

    func set(_ families: [GenreFamily]?, forTag raw: String) {
        let k = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        lock.lock()
        if let families { map[k] = families.map(\.rawValue) } else { map.removeValue(forKey: k) }
        let snapshot = map
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }
}
