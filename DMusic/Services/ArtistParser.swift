import Foundation

/// Utilitário central para separar artistas combinados (ex.: "Madonna com Sabrina Carpenter",
/// "Madonna feat. Sabrina Carpenter", "Madonna & Sabrina Carpenter", "Madonna; Sabrina Carpenter")
/// em artistas individuais, formatar exibição separada por vírgula e verificar participações.
nonisolated enum ArtistParser {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String
        let name: String
        var coverArt: String?
    }

    /// Bandas únicas cujo nome oficial contém "&", "+" ou "," e não devem ser divididas.
    private static let indivisibleBands: Set<String> = [
        "ac/dc", "earth, wind & fire", "guns n' roses", "florence + the machine",
        "florence & the machine", "twenty one pilots", "tyler, the creator",
        "crosby, stills & nash", "crosby, stills, nash & young",
        "emerson, lake & palmer", "mumford & sons", "belle & sebastian",
        "coheed and cambria", "iron & wine", "king gizzard & the lizard wizard",
        "the mamas & the papas", "simon & garfunkel", "hall & oates"
    ]

    /// Extrai a lista de artistas individuais de uma `Song`.
    static func artists(for song: Song) -> [Entry] {
        var result: [Entry] = []
        var seen: Set<String> = []

        func append(name: String, id: String?, cover: String?) {
            for part in splitNames(from: name) {
                let key = part.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                // Só preserva o ID original se o nome não foi dividido de um nome composto
                let cleanOriginal = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let useId = (cleanOriginal.caseInsensitiveCompare(part) == .orderedSame) ? (id ?? "name:\(part)") : "name:\(part)"
                result.append(Entry(id: useId, name: part, coverArt: cover))
            }
        }

        if let structured = song.artists, !structured.isEmpty {
            for item in structured {
                append(name: item.name, id: item.id, cover: song.coverArt)
            }
        }
        if let raw = song.artist, !raw.isEmpty {
            append(name: raw, id: song.artistId, cover: song.coverArt)
        }
        if let display = song.displayArtist, !display.isEmpty {
            append(name: display, id: nil, cover: song.coverArt)
        }
        // Também extrai participações embutidas no título da música, ex.: "Bring Your Love (feat. Sabrina Carpenter)"
        for guest in extractFeaturedFromTitle(song.title) {
            append(name: guest, id: nil, cover: song.coverArt)
        }

        return result
    }

    /// Extrai a lista de artistas individuais de um `Album`.
    static func artists(for album: Album) -> [Entry] {
        var result: [Entry] = []
        var seen: Set<String> = []

        func append(name: String, id: String?) {
            for part in splitNames(from: name) {
                let key = part.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                let cleanOriginal = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let useId = (cleanOriginal.caseInsensitiveCompare(part) == .orderedSame) ? (id ?? "name:\(part)") : "name:\(part)"
                result.append(Entry(id: useId, name: part, coverArt: album.coverArt))
            }
        }

        if let raw = album.artist, !raw.isEmpty {
            append(name: raw, id: album.artistId)
        }
        if let songs = album.song {
            for s in songs {
                for a in artists(for: s) {
                    let key = a.name.lowercased()
                    if !seen.contains(key) {
                        seen.insert(key)
                        result.append(a)
                    }
                }
            }
        }
        return result
    }

    /// Formata os artistas da faixa sempre separados por vírgula (ex.: "Madonna, Sabrina Carpenter").
    static func displayString(for song: Song) -> String {
        let list = artists(for: song).map(\.name)
        if !list.isEmpty { return list.joined(separator: ", ") }
        return song.artist ?? ""
    }

    /// Formata os artistas de uma string bruta sempre separados por vírgula.
    static func displayString(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let list = splitNames(from: raw)
        return list.isEmpty ? raw : list.joined(separator: ", ")
    }

    /// Divide qualquer string de artistas combinados em nomes individuais.
    static func splitNames(from raw: String) -> [String] {
        var s = raw
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }

        if indivisibleBands.contains(s.lowercased()) {
            return [s]
        }

        // Remove parênteses/colchetes em torno de feat/com/with para virar separador normal
        s = replaceRegex(
            in: s,
            pattern: #"(?i)[\(\[\{]\s*(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?|part\.?|participa[çc][ãa]o(?:\s+especial)?(?:\s+de)?|with|com)\s+([^\)\]\}]*)[\)\]\}]"#,
            with: " , $1 "
        )

        // Substitui conectores verbais ("feat.", "ft.", "featuring", "with", "com", "part.", "vs.", " x ") por vírgula
        s = replaceRegex(
            in: s,
            pattern: #"(?i)(?:\s+[-–—]\s+|\s+)(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?|part\.?|participa[çc][ãa]o(?:\s+especial)?(?:\s+de)?|with|com|vs\.?|x)(?:\s+)"#,
            with: " , "
        )

        // Substitui separadores explícitos (";", "/", "|", "•", "·", "+") por vírgula (preservando AC/DC)
        if s.lowercased() != "ac/dc" {
            s = replaceRegex(in: s, pattern: #"\s*(?:;|/|\||•|·|\+)\s*"#, with: " , ")
        }

        // Primeiro divide por vírgula
        let commaChunks = s.components(separatedBy: ",")
        var results: [String] = []
        var seen: Set<String> = []

        var i = 0
        while i < commaChunks.count {
            let chunk = collapseSpaces(commaChunks[i])
            if chunk.isEmpty { i += 1; continue }

            // Protege "Tyler, The Creator"
            if chunk.lowercased() == "tyler", i + 1 < commaChunks.count,
               collapseSpaces(commaChunks[i + 1]).lowercased() == "the creator" {
                let combined = "Tyler, The Creator"
                let key = combined.lowercased()
                if !seen.contains(key) { seen.insert(key); results.append(combined) }
                i += 2
                continue
            }

            // Divide por " & " e " e " quando não for banda indivisível
            let subParts: [String]
            if indivisibleBands.contains(chunk.lowercased()) {
                subParts = [chunk]
            } else {
                let normalizedAmp = replaceRegex(in: chunk, pattern: #"(?i)\s+(?:&|and)\s+"#, with: " & ")
                if normalizedAmp.contains(" & ") && !indivisibleBands.contains(normalizedAmp.lowercased()) {
                    subParts = normalizedAmp.components(separatedBy: " & ").map(collapseSpaces)
                } else {
                    subParts = [chunk]
                }
            }

            for part in subParts {
                let cleaned = part.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}-–— ").union(.whitespacesAndNewlines))
                let key = cleaned.lowercased()
                guard !cleaned.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                results.append(cleaned)
            }
            i += 1
        }

        return results
    }

    /// Extrai artistas convidados presentes no título da faixa, ex.: "Song (feat. Sabrina Carpenter)"
    static func extractFeaturedFromTitle(_ title: String) -> [String] {
        let pattern = #"(?i)(?:[\(\[\{]\s*|\s+[-–—]?\s*\b)(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?|part\.?|participa[çc][ãa]o(?:\s+especial)?(?:\s+de)?|with)\s+([^\)\]\}]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(title.startIndex..<title.endIndex, in: title)
        let matches = regex.matches(in: title, range: nsRange)
        var out: [String] = []
        for m in matches where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            if r.location != NSNotFound, let sr = Range(r, in: title) {
                out.append(contentsOf: splitNames(from: String(title[sr])))
            }
        }
        return out
    }

    /// Normaliza uma lista de `Artist` vinda do servidor, separando qualquer entrada combinada
    /// em artistas individuais sem duplicatas.
    static func normalizeArtistList(_ rawArtists: [Artist]) -> [Artist] {
        // Primeiro passo: registra os artistas que já existem individualmente no servidor (para preservar o ID real deles)
        var exactById: [String: Artist] = [:]
        for a in rawArtists {
            let parts = splitNames(from: a.name)
            if parts.count == 1 {
                let name = parts[0]
                let key = name.lowercased()
                if exactById[key] == nil {
                    exactById[key] = Artist(id: a.id, name: name, coverArt: a.coverArt, albumCount: a.albumCount, album: a.album)
                }
            }
        }

        var merged: [String: Artist] = exactById
        for a in rawArtists {
            let parts = splitNames(from: a.name)
            for part in parts {
                let key = part.lowercased()
                if var existing = merged[key] {
                    if existing.coverArt == nil, let c = a.coverArt { existing.coverArt = c }
                    // Se veio de uma entrada combinada, soma na contagem estimada de álbuns
                    if parts.count > 1, let add = a.albumCount, add > 0 {
                        existing.albumCount = (existing.albumCount ?? 0) + add
                    }
                    merged[key] = existing
                } else {
                    // Artista que só existia dentro de colaboração ganha entrada própria individual
                    let id = (parts.count == 1) ? a.id : "name:\(part)"
                    merged[key] = Artist(id: id, name: part, coverArt: a.coverArt, albumCount: a.albumCount, album: nil)
                }
            }
        }

        return merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Verifica se o artista `targetName` participa da `Song` (como artista principal, convidado ou no título).
    static func songMatchesArtist(_ song: Song, artistName targetName: String) -> Bool {
        let target = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return artists(for: song).contains { $0.name.lowercased() == target }
    }

    /// Verifica se o artista `targetName` é autor ou participante do `Album`.
    static func albumMatchesArtist(_ album: Album, artistName targetName: String) -> Bool {
        let target = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return artists(for: album).contains { $0.name.lowercased() == target }
    }

    private static func collapseSpaces(_ s: String) -> String {
        replaceRegex(in: s, pattern: #"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceRegex(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
