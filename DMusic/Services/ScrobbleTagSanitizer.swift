import Foundation

/// Normaliza e limpa metadados OpenSubsonic/Navidrome antes de enviar para a API 2.0 do Last.fm
/// (inspirado nas regras do Pano Scrobbler / Web Scrobbler / especificações oficiais do Last.fm).
nonisolated enum ScrobbleTagSanitizer {
    struct Options: Sendable {
        var usePrimaryArtistOnly: Bool = true
        var stripTitleExtras: Bool = true
        var stripAlbumExtras: Bool = true
        var cleanFileArtifacts: Bool = true
    }

    struct CleanedTrack: Sendable, Equatable {
        let artist: String
        let title: String
        let album: String?
        let albumArtist: String?
        let trackNumber: Int?
        let duration: Int?
    }

    // Artistas compostos conhecidos que NÃO devem ser quebrados em "&" ou ","
    private static let compoundArtists: Set<String> = [
        "ac/dc", "simon & garfunkel", "hall & oates", "daryl hall & john oates",
        "earth, wind & fire", "crosby, stills & nash", "crosby, stills, nash & young",
        "emerson, lake & palmer", "mumford & sons", "florence + the machine",
        "florence & the machine", "belle & sebastian", "tegan and sara", "tegan & sara",
        "angus & julia stone", "coheed and cambria", "guns n' roses", "iron & wine",
        "she & him", "aly & aj", "brooks & dunn", "dan + shay", "twenty one pilots",
        "king gizzard & the lizard wizard", "the mamas & the papas", "ike & tina turner",
        "sonny & cher", "penn & teller", "sandy & junior", "chitãozinho & xororó",
        "zeze di camargo & luciano", "zezé di camargo & luciano", "jorge & mateus",
        "henrique & juliano", "matheus & kauan", "maiara & maraisa", "simone & simaria",
        "bruno & marrone", "leandro & leonardo", "victor & leo", "milionário & josé rico",
        "chrystian & ralf", "rick & renner", "edson & hudson", "guilherme & santiago",
        "fernando & sorocaba", "thaeme & thiago", "israel & rodolffo", "zé neto & cristiano",
        "césar menotti & fabiano", "joão bosco & vinícius", "marcos & belutti"
    ]

    static func clean(_ song: Song, albumFallbackArtist: String? = nil, options: Options = Options()) -> CleanedTrack {
        // 1. Título bruto normalizado em NFC
        var title = normalizeUnicode(song.title)
        var rawArtist = normalizeUnicode(primaryRawArtist(from: song))
        var album = song.album.map(normalizeUnicode)
        var albumArtist = rawAlbumArtist(from: song, fallback: albumFallbackArtist).map(normalizeUnicode)

        // 2. Limpeza de artefatos de nome de arquivo (extensão, número inicial, "Artista - Faixa")
        if options.cleanFileArtifacts {
            title = stripAudioExtension(title)
            title = stripLeadingTrackNumber(title, expectedTrack: song.track)

            // Caso clássico de tag mal importada onde title veio como "Artista - Música"
            if let (embeddedArtist, embeddedTitle) = splitArtistDashTitle(title, knownArtist: rawArtist, path: song.path) {
                if rawArtist.isEmpty || isUnknownArtist(rawArtist) {
                    rawArtist = embeddedArtist
                }
                title = embeddedTitle
            }
        }

        // 3. Se no título veio "(feat. X)" e optou por limpar extras, removemos o feat do título
        if options.stripTitleExtras {
            title = stripFeaturedFromText(title)
            title = stripEditionNoise(title, isAlbum: false)
        }

        if let alb = album, !alb.isEmpty {
            var cleanedAlb = options.cleanFileArtifacts ? stripAudioExtension(alb) : alb
            if options.stripAlbumExtras {
                cleanedAlb = stripFeaturedFromText(cleanedAlb)
                cleanedAlb = stripEditionNoise(cleanedAlb, isAlbum: true)
            }
            cleanedAlb = collapseSpaces(cleanedAlb)
            album = cleanedAlb.isEmpty || isUnknownAlbum(cleanedAlb) ? nil : cleanedAlb
        } else {
            album = nil
        }

        // 4. Artista principal
        var artist = rawArtist
        if options.usePrimaryArtistOnly {
            // Se o Navidrome enviou o array estruturado `artists` (OpenSubsonic), o primeiro item é exato!
            if let firstStructured = song.artists?.first?.name.trimmingCharacters(in: .whitespacesAndNewlines),
               !firstStructured.isEmpty {
                artist = normalizeUnicode(firstStructured)
            } else {
                artist = extractPrimaryArtist(from: artist)
            }
        }

        if let aa = albumArtist, !aa.isEmpty {
            let cleanAA: String
            if let firstAA = song.albumArtists?.first?.name.trimmingCharacters(in: .whitespacesAndNewlines),
               !firstAA.isEmpty, options.usePrimaryArtistOnly {
                cleanAA = normalizeUnicode(firstAA)
            } else {
                cleanAA = options.usePrimaryArtistOnly ? extractPrimaryArtist(from: aa) : aa
            }
            albumArtist = collapseSpaces(cleanAA)
            if albumArtist?.isEmpty == true || isUnknownArtist(albumArtist ?? "") {
                albumArtist = nil
            }
        } else {
            albumArtist = nil
        }

        artist = collapseSpaces(artist)
        title = collapseSpaces(title)

        // Fallback seguro caso a limpeza tenha esvaziado o título
        if title.isEmpty {
            title = collapseSpaces(normalizeUnicode(song.title))
        }
        if artist.isEmpty, let aa = albumArtist {
            artist = aa
        }

        return CleanedTrack(
            artist: artist,
            title: title,
            album: album,
            albumArtist: albumArtist,
            trackNumber: (song.track ?? 0) > 0 ? song.track : nil,
            duration: (song.duration ?? 0) > 0 ? song.duration : nil
        )
    }

    // MARK: - Helpers de extração

    private static func primaryRawArtist(from song: Song) -> String {
        if let first = song.artists?.first?.name, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Ainda retornamos `song.artist` abaixo se `usePrimaryArtistOnly == false`, então aqui pegamos o bruto completo:
        }
        if let a = song.artist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        if let da = song.displayArtist, !da.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return da }
        if let list = song.artists, !list.isEmpty { return list.map(\.name).joined(separator: ", ") }
        return ""
    }

    private static func rawAlbumArtist(from song: Song, fallback: String?) -> String? {
        if let list = song.albumArtists, let first = list.first?.name, !first.isEmpty {
            return list.map(\.name).joined(separator: ", ")
        }
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return nil
    }

    static func extractPrimaryArtist(from raw: String) -> String {
        let trimmed = collapseSpaces(raw)
        guard !trimmed.isEmpty else { return trimmed }
        if compoundArtists.contains(trimmed.lowercased()) { return trimmed }

        // 1. Remove qualquer sufixo de participação explícita: feat., ft., featuring, part., com, with...
        let featPatterns = [
            #"(?i)\s*[\(\[\{]?\b(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?|part\.?|participa[çc][ãa]o\s+de|with)\b.*$"#,
            #"(?i)\s+\b(?:vs\.?|x)\b\s+.*$"#
        ]
        var s = trimmed
        for p in featPatterns {
            s = replaceRegex(in: s, pattern: p, with: "")
        }
        s = collapseSpaces(s)
        if compoundArtists.contains(s.lowercased()) { return s }

        // 2. Separadores inequívocos de múltiplos artistas em tags ID3/FLAC/Navidrome (`;`, `/`, `•`, `|`)
        for sep in [" ; ", "; ", ";", " / ", " • ", " · ", " | "] {
            if let range = s.range(of: sep) {
                let first = collapseSpaces(String(s[..<range.lowerBound]))
                if !first.isEmpty { return first }
            }
        }

        // 3. Vírgula ("Artista 1, Artista 2") se não for nome composto protegido
        if s.contains(",") && !compoundArtists.contains(s.lowercased()) {
            let parts = s.components(separatedBy: ",").map(collapseSpaces).filter { !$0.isEmpty }
            // Evita cortar "Tyler, The Creator"
            if parts.count >= 2, parts[1].lowercased() != "the creator" {
                return parts[0]
            }
        }

        // 4. " & " quando houver mais de 2 artistas ou não estiver na lista de duplas conhecidas
        if s.contains(" & ") && !compoundArtists.contains(s.lowercased()) {
            let parts = s.components(separatedBy: " & ").map(collapseSpaces).filter { !$0.isEmpty }
            if let first = parts.first, !first.isEmpty {
                return first
            }
        }

        return s
    }

    private static func stripAudioExtension(_ s: String) -> String {
        replaceRegex(in: s, pattern: #"(?i)\.(flac|mp3|m4a|alac|wav|ogg|opus|aac|aiff|dsf|dff|wv)$"#, with: "")
    }

    private static func stripLeadingTrackNumber(_ s: String, expectedTrack: Int?) -> String {
        // Ex.: "01 - Come Together", "01. Come Together", "1-03 Come Together"
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = firstMatch(in: trimmed, pattern: #"^(?:(\d{1,2})-)?(\d{1,3})\s*(?:[-–—.]\s+|\s+-\s+)(.+)$"#) {
            if let numStr = match[2], let num = Int(numStr) {
                // Se bate com o número da faixa OU tem formato explícito com zero à esquerda ("01 - ...")
                if expectedTrack == num || numStr.hasPrefix("0") {
                    if let rest = match[3], !rest.isEmpty { return rest }
                }
            }
        }
        return s
    }

    private static func splitArtistDashTitle(_ title: String, knownArtist: String, path: String?) -> (String, String)? {
        // Só divide "Artista - Música" se:
        // a) o artista da música estiver vazio/"Unknown Artist", OU
        // b) o prefixo antes de " - " for exatamente igual ao `knownArtist` (tag duplicada no título, ex.: "Radiohead - Creep")
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        let candidateArtist = collapseSpaces(parts[0])
        let candidateTitle = collapseSpaces(parts.dropFirst().joined(separator: " - "))
        guard !candidateArtist.isEmpty, !candidateTitle.isEmpty else { return nil }

        if knownArtist.isEmpty || isUnknownArtist(knownArtist) {
            return (candidateArtist, candidateTitle)
        }
        if candidateArtist.caseInsensitiveCompare(knownArtist) == .orderedSame {
            return (knownArtist, candidateTitle)
        }
        // Ou se o título for literalmente igual ao nome do arquivo sem extensão
        if let path, let file = path.split(separator: "/").last {
            let fileNoExt = stripAudioExtension(String(file))
            if fileNoExt.caseInsensitiveCompare(title) == .orderedSame,
               candidateArtist.localizedCaseInsensitiveContains(knownArtist) || knownArtist.localizedCaseInsensitiveContains(candidateArtist) {
                return (knownArtist, candidateTitle)
            }
        }
        return nil
    }

    private static func stripFeaturedFromText(_ s: String) -> String {
        var out = s
        let patterns = [
            // Entre parênteses ou colchetes: (feat. X), [ft. Y], (with Z), (part. W)
            #"(?i)\s*[\(\[\{]\s*(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?|part\.?|participa[çc][ãa]o(?:\s+especial)?(?:\s+de)?|with)\s+[^\)\]\}]*[\)\]\}]"#,
            // Solto no fim: " - feat. X" ou " feat. X"
            #"(?i)\s*(?:[-–—]\s*)?\b(?:feat\.?|ft\.?|featuring|part\.?\s*esp\.?)\s+.+$"#
        ]
        for p in patterns {
            out = replaceRegex(in: out, pattern: p, with: "")
        }
        return out
    }

    private static func stripEditionNoise(_ s: String, isAlbum: Bool) -> String {
        var out = s
        // Parênteses/colchetes de remaster, deluxe, edition, bonus, explicit, etc. (preserva "(Live ...)" e "(Acoustic)" em faixas!)
        let bracketNoise = isAlbum
            ? #"(?i)\s*[\(\[\{][^\)\]\}]*\b(?:remaster(?:ed)?|deluxe|expanded|anniversary|special\s+edition|collector'?s\s+edition|bonus\s+track(?:s)?|standard\s+edition|explicit|clean|hi-?res|24-?bit|\d{4}\s+mix|\d{4}\s+version|edition|reedition|re-?issue)\b[^\)\]\}]*[\)\]\}]"#
            : #"(?i)\s*[\(\[\{][^\)\]\}]*\b(?:remaster(?:ed)?|album\s+version|single\s+version|explicit|clean|bonus\s+track|audio|official\s+(?:video|audio|music\s+video)|lyric\s+video|hd|hq|\d{4}\s+remaster(?:ed)?)\b[^\)\]\}]*[\)\]\}]"#

        out = replaceRegex(in: out, pattern: bracketNoise, with: "")

        // Sufixo com traço tipo " - Remastered 2011", " - 2009 Remaster", " - Deluxe Edition"
        let dashNoise = isAlbum
            ? #"(?i)\s+[-–—]\s+(?:\d{4}\s+)?(?:remaster(?:ed)?(?:\s+\d{4})?|deluxe(?:\s+edition)?|expanded\s+edition|special\s+edition|bonus\s+track\s+version|anniversary\s+edition).*$"#
            : #"(?i)\s+[-–—]\s+(?:\d{4}\s+)?(?:remaster(?:ed)?(?:\s+\d{4})?|album\s+version|single\s+version|explicit(?:\s+version)?|bonus\s+track).*$"#

        out = replaceRegex(in: out, pattern: dashNoise, with: "")
        return out
    }

    private static func isUnknownArtist(_ s: String) -> Bool {
        let l = s.lowercased()
        return l == "unknown artist" || l == "<unknown>" || l == "artista desconhecido" || l == "unknown"
    }

    private static func isUnknownAlbum(_ s: String) -> Bool {
        let l = s.lowercased()
        return l == "unknown album" || l == "<unknown>" || l == "álbum desconhecido" || l == "unknown"
    }

    private static func normalizeUnicode(_ s: String) -> String {
        // NFC garante que letras acentuadas (ex.: "ã", "é", "ç") nunca fiquem decompostas em NFD (o que quebrava no Last.fm)
        s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
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

    private static func firstMatch(in text: String, pattern: String) -> [Int: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: nsRange) else { return nil }
        var groups: [Int: String] = [:]
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound, let sr = Range(r, in: text) {
                groups[i] = String(text[sr])
            }
        }
        return groups
    }
}
