import Foundation
import Observation

/// Biblioteca inteira classificada por gênero: cada música entra em todas as famílias/subgêneros das suas tags.
/// Alimenta os modos de mix (pool de músicas) e a tela de gêneros.
@Observable
@MainActor
final class GenreLibrary {
    private(set) var isLoading = false
    private(set) var loaded = false
    @ObservationIgnored private var allSongs: [Song] = []
    @ObservationIgnored private var byFamily: [GenreFamily: [Song]] = [:]
    @ObservationIgnored private var byTag: [GenreTag: [Song]] = [:]
    @ObservationIgnored private var seenRevision = GenreAssignments.shared.revision

    /// Abaixo disso o pool é ampliado com famílias vizinhas.
    static let minimumPool = 40

    func load(client: SubsonicClient) async {
        if loaded || isLoading { return }
        isLoading = true
        defer { isLoading = false }
        var songs: [Song] = []
        var known = Set<String>()
        var offset = 0
        for _ in 0..<60 {
            guard let page = try? await client.songs(offset: offset, count: 500), !page.isEmpty else { break }
            let fresh = page.filter { known.insert($0.id).inserted }
            if fresh.isEmpty { break }
            songs += fresh
            if page.count < 500 { break }
            offset += page.count
        }
        allSongs = songs
        loaded = !songs.isEmpty
        reclassify()
    }

    /// Reaplica as regras (chamar após ajustes manuais de gênero).
    func reclassify() {
        var fam: [GenreFamily: [Song]] = [:]
        var tag: [GenreTag: [Song]] = [:]
        for s in allSongs {
            let tags = GenreTaxonomy.tags(for: s)
            for f in Set(tags.map(\.family)) { fam[f, default: []].append(s) }
            for t in tags { tag[t, default: []].append(s) }
        }
        byFamily = fam
        byTag = tag
        seenRevision = GenreAssignments.shared.revision
    }

    func count(family: GenreFamily, sub: String? = nil) -> Int {
        songs(family: family, sub: sub).count
    }

    func songs(family: GenreFamily, sub: String? = nil) -> [Song] {
        // Ajustes de gênero feitos depois da última classificação
        if seenRevision != GenreAssignments.shared.revision { reclassify() }
        if let sub { return byTag[GenreTag(family: family, sub: sub)] ?? [] }
        return byFamily[family] ?? []
    }

    /// Pool de um modo: a família (ou subgênero) escolhida; se tiver poucas músicas, soma famílias vizinhas
    /// na ordem de proximidade e informa quais entraram.
    func pool(family: GenreFamily, sub: String? = nil) -> (songs: [Song], expandedWith: [GenreFamily]) {
        var result = songs(family: family, sub: sub)
        var ids = Set(result.map(\.id))
        var added: [GenreFamily] = []
        if result.count < Self.minimumPool {
            for n in family.neighbors {
                let extra = (byFamily[n] ?? []).filter { ids.insert($0.id).inserted }
                if extra.isEmpty { continue }
                result += extra
                added.append(n)
                if result.count >= Self.minimumPool { break }
            }
        }
        return (result, added)
    }

    /// Músicas por família somando as tags cruas do Navidrome (rápido: não precisa baixar a biblioteca).
    /// Uma tag que vale para duas famílias conta nas duas. Famílias vazias ficam de fora; "Outros" vai por último.
    static func familyCounts(_ genres: [GenreInfo]) -> [(family: GenreFamily, count: Int)] {
        var totals: [GenreFamily: Int] = [:]
        for g in genres {
            let tags = GenreTaxonomy.tags(forTag: g.value)
            for f in Set((tags.isEmpty ? [GenreTag(family: .other, sub: nil)] : Array(tags)).map(\.family)) {
                totals[f, default: 0] += g.songCount ?? 0
            }
        }
        return totals.filter { $0.value > 0 }
            .map { (family: $0.key, count: $0.value) }
            .sorted { a, b in
                if (a.family == .other) != (b.family == .other) { return b.family == .other }
                return a.count > b.count
            }
    }

    /// Monta o pool (ampliando com vizinhas se for pequeno) e toca. Devolve um aviso quando ampliou ou não achou nada.
    func startMix(title: String, family: GenreFamily, sub: String? = nil, automix: Bool,
                  client: SubsonicClient, player: AudioPlayerManager) async -> String? {
        if !loaded { await load(client: client) }
        let result = pool(family: family, sub: sub)
        guard !result.songs.isEmpty else { return "Nenhuma música encontrada em \(title)." }
        player.playGenreMix(title: title, songs: result.songs, automix: automix)
        guard !result.expandedWith.isEmpty else { return nil }
        let own = count(family: family, sub: sub)
        return "“\(title)” tem só \(own) músicas. Para não repetir demais, entraram também: \(result.expandedWith.map(\.rawValue).joined(separator: ", ")). Total: \(result.songs.count)."
    }
}
