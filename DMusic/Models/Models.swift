import Foundation

nonisolated struct SongArtistRef: Codable, Hashable, Sendable {
    let id: String?
    let name: String
}

nonisolated struct SongGenreRef: Codable, Hashable, Sendable {
    let name: String
}

nonisolated struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var artist: String?
    var displayArtist: String?
    var artists: [SongArtistRef]?
    var albumArtists: [SongArtistRef]?
    var album: String?
    var albumId: String?
    var artistId: String?
    var coverArt: String?
    var duration: Int?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    /// OpenSubsonic: "explicit", "clean" ou vazio (vem da tag de conteúdo explícito do arquivo).
    var explicitStatus: String?
    /// Lista de gêneros (OpenSubsonic); `genre` traz só o primeiro/concatenado.
    var genres: [SongGenreRef]?
    var path: String?
    var musicBrainzId: String?
    var suffix: String?
    var bitRate: Int?
    var bitDepth: Int?
    var samplingRate: Int?

    /// Ex.: "FLAC 24-bit / 96kHz" ou "MP3 320 kbps"
    var qualityText: String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        let format = suffix.uppercased()
        if let bitDepth, bitDepth > 0, let samplingRate, samplingRate > 0 {
            return "\(format) \(bitDepth)-bit / \(Song.formatKHz(samplingRate))"
        }
        if let bitRate, bitRate > 0 { return "\(format) \(bitRate) kbps" }
        return format
    }

    var isExplicit: Bool { explicitStatus?.lowercased() == "explicit" }

    var isHiRes: Bool { (bitDepth ?? 0) > 16 || (samplingRate ?? 0) > 44100 }

    static func formatKHz(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
    }
}

nonisolated struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    var title: String?
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var year: Int?
    var songCount: Int?
    var song: [Song]?

    var displayName: String { name ?? title ?? "Álbum desconhecido" }
}

nonisolated struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?
    var albumCount: Int?
    var album: [Album]?
}

nonisolated struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?
    var songCount: Int?
    var entry: [Song]?
}

/// Gênero cru do Navidrome (`getGenres`) com contagens.
nonisolated struct GenreInfo: Decodable, Hashable, Sendable {
    let value: String
    let songCount: Int?
    let albumCount: Int?
}

nonisolated struct SubsonicResponse: Decodable, Sendable {
    struct APIError: Decodable, Sendable { let code: Int?; let message: String? }
    struct AlbumList: Decodable, Sendable { let album: [Album]? }
    struct ArtistIndex: Decodable, Sendable { let name: String?; let artist: [Artist]? }
    struct Artists: Decodable, Sendable { let index: [ArtistIndex]? }
    struct Playlists: Decodable, Sendable { let playlist: [Playlist]? }
    struct SongList: Decodable, Sendable { let song: [Song]? }
    struct Genres: Decodable, Sendable { let genre: [GenreInfo]? }
    struct SearchResult: Decodable, Sendable {
        let artist: [Artist]?
        let album: [Album]?
        let song: [Song]?
    }
    struct Body: Decodable, Sendable {
        let status: String
        let error: APIError?
        let albumList2: AlbumList?
        let artists: Artists?
        let playlists: Playlists?
        let playlist: Playlist?
        let album: Album?
        let artist: Artist?
        let song: Song?
        let searchResult3: SearchResult?
        let starred2: SearchResult?
        let randomSongs: SongList?
        let genres: Genres?
    }
    let body: Body
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

enum AppTab: String, Hashable, Sendable {
    case home, library, search
}

nonisolated enum PlaybackSource: Codable, Hashable, Sendable {
    case album(Album)
    case playlist(Playlist)
    case artist(Artist)
    case library(sectionRaw: String, title: String)
    case search(query: String)
    case djMix(seedTitle: String)

    var headerLabel: String {
        switch self {
        case .album: return "TOCANDO DO ÁLBUM"
        case .playlist: return "TOCANDO DA PLAYLIST"
        case .artist: return "TOCANDO DO ARTISTA"
        case .library: return "TOCANDO DA BIBLIOTECA"
        case .search: return "TOCANDO DA BUSCA"
        case .djMix: return "TOCANDO DO MIX DE"
        }
    }

    var title: String {
        switch self {
        case .album(let a): return a.displayName
        case .playlist(let p): return p.name
        case .artist(let a): return a.name
        case .library(_, let title): return title
        case .search(let q): return q.isEmpty ? "Busca" : "“\(q)”"
        case .djMix(let seedTitle): return seedTitle
        }
    }

    var isNavigable: Bool {
        if case .djMix = self { return false }
        return true
    }
}
