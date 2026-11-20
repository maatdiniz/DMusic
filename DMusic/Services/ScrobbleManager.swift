import Foundation
import Network
import Observation

nonisolated struct PendingScrobble: Codable, Identifiable, Sendable {
    let id: UUID
    let songId: String
    let title: String
    let artist: String
    let album: String?
    var albumArtist: String?
    var trackNumber: Int?
    let duration: Int?
    let timestamp: Int       // segundos desde 1970 (quando a faixa começou)
    var navidrome: Bool      // ainda falta enviar ao Navidrome
    var lastfm: Bool         // ainda falta enviar ao Last.fm
}

/// Fila persistente de scrobbles (Navidrome e Last.fm). Funciona offline: grava no disco e
/// envia em lote quando houver rede (mudança de rede, app ativo, novo scrobble ou envio manual).
@Observable
@MainActor
final class ScrobbleManager {
    private(set) var pending: [PendingScrobble] = []
    private(set) var isFlushing = false
    private(set) var isOnline = true
    var lastError: String?
    var client: SubsonicClient?

    private(set) var lastfmUser: String?
    var lastfmEnabled: Bool { didSet { UserDefaults.standard.set(lastfmEnabled, forKey: "lf_enabled") } }
    var sendToNavidrome: Bool { didSet { UserDefaults.standard.set(sendToNavidrome, forKey: "navidrome_scrobble") } }
    var usePrimaryArtistOnly: Bool { didSet { UserDefaults.standard.set(usePrimaryArtistOnly, forKey: "lf_primary_artist") } }
    var stripTitleExtras: Bool { didSet { UserDefaults.standard.set(stripTitleExtras, forKey: "lf_strip_title") } }
    var stripAlbumExtras: Bool { didSet { UserDefaults.standard.set(stripAlbumExtras, forKey: "lf_strip_album") } }
    var cleanFileArtifacts: Bool { didSet { UserDefaults.standard.set(cleanFileArtifacts, forKey: "lf_clean_file") } }
    private(set) var lastPrepared: ScrobbleTagSanitizer.CleanedTrack?

    var isLastFMConnected: Bool { lastfmUser != nil && KeychainStore.get(Key.session) != nil }
    var pendingLastFM: Int { pending.filter(\.lastfm).count }
    var pendingNavidrome: Int { pending.filter(\.navidrome).count }

    private enum Key { static let apiKey = "lf_api_key", secret = "lf_secret", session = "lf_session", user = "lf_user" }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("pending_scrobbles.json")
        let d = UserDefaults.standard
        lastfmEnabled = d.object(forKey: "lf_enabled") as? Bool ?? true
        sendToNavidrome = d.object(forKey: "navidrome_scrobble") as? Bool ?? true
        usePrimaryArtistOnly = d.object(forKey: "lf_primary_artist") as? Bool ?? true
        stripTitleExtras = d.object(forKey: "lf_strip_title") as? Bool ?? true
        stripAlbumExtras = d.object(forKey: "lf_strip_album") as? Bool ?? true
        cleanFileArtifacts = d.object(forKey: "lf_clean_file") as? Bool ?? true
        lastfmUser = d.string(forKey: Key.user)
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([PendingScrobble].self, from: data) {
            pending = list
        }
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "scrobble.network"))
    }

    private func networkChanged(_ online: Bool) {
        let was = isOnline
        isOnline = online
        if online && !was { Task { await flush() } }
    }

    // MARK: Last.fm account

    /// API Key padrão do app (salva no Keychain pelo usuário no primeiro login).
    var apiKey: String { KeychainStore.get(Key.apiKey) ?? "" }
    var secret: String { KeychainStore.get(Key.secret) ?? "" }

    private func lastFMClient() -> LastFMClient? {
        guard lastfmEnabled, let sk = KeychainStore.get(Key.session), !apiKey.isEmpty, !secret.isEmpty else { return nil }
        return LastFMClient(apiKey: apiKey, secret: secret, sessionKey: sk)
    }

    func connectLastFM(apiKey: String, secret: String, username: String, password: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = LastFMClient(apiKey: key, secret: sec, sessionKey: nil)
        let s = try await c.mobileSession(username: username.trimmingCharacters(in: .whitespaces), password: password)
        KeychainStore.set(key, for: Key.apiKey)
        KeychainStore.set(sec, for: Key.secret)
        KeychainStore.set(s.key, for: Key.session)
        UserDefaults.standard.set(s.name, forKey: Key.user)
        lastfmUser = s.name
        lastfmEnabled = true
        lastError = nil
        await flush()
    }

    func disconnectLastFM() {
        KeychainStore.remove(Key.session)
        UserDefaults.standard.removeObject(forKey: Key.user)
        lastfmUser = nil
        for i in pending.indices { pending[i].lastfm = false }
        pending.removeAll { !$0.navidrome && !$0.lastfm }
        save()
    }

    // MARK: Registro

    var tagOptions: ScrobbleTagSanitizer.Options {
        .init(
            usePrimaryArtistOnly: usePrimaryArtistOnly,
            stripTitleExtras: stripTitleExtras,
            stripAlbumExtras: stripAlbumExtras,
            cleanFileArtifacts: cleanFileArtifacts
        )
    }

    func cleanedTags(for song: Song, albumFallbackArtist: String? = nil) -> ScrobbleTagSanitizer.CleanedTrack {
        ScrobbleTagSanitizer.clean(song, albumFallbackArtist: albumFallbackArtist, options: tagOptions)
    }

    /// Chamado quando a faixa atingiu a regra de scrobble (≥ 50% ou 4 min, faixa > 30 s).
    func scrobble(_ song: Song, startedAt: Date, albumFallbackArtist: String? = nil) {
        let toNavidrome = sendToNavidrome && client != nil
        let toLastFM = lastfmEnabled && isLastFMConnected
        guard toNavidrome || toLastFM else { return }
        let cleaned = cleanedTags(for: song, albumFallbackArtist: albumFallbackArtist)
        lastPrepared = cleaned
        pending.append(PendingScrobble(
            id: UUID(), songId: song.id, title: cleaned.title,
            artist: cleaned.artist, album: cleaned.album,
            albumArtist: cleaned.albumArtist, trackNumber: cleaned.trackNumber,
            duration: cleaned.duration,
            timestamp: Int(startedAt.timeIntervalSince1970),
            navidrome: toNavidrome, lastfm: toLastFM && !cleaned.artist.isEmpty && !cleaned.title.isEmpty))
        save()
        Task { await flush() }
    }

    func nowPlaying(_ song: Song, albumFallbackArtist: String? = nil) {
        let cleaned = cleanedTags(for: song, albumFallbackArtist: albumFallbackArtist)
        lastPrepared = cleaned
        guard isOnline, let lf = lastFMClient(), !cleaned.artist.isEmpty, !cleaned.title.isEmpty else { return }
        let t = LastFMClient.Track(
            artist: cleaned.artist, title: cleaned.title, album: cleaned.album,
            albumArtist: cleaned.albumArtist, trackNumber: cleaned.trackNumber,
            duration: cleaned.duration, timestamp: 0
        )
        Task { try? await lf.updateNowPlaying(t) }
    }

    // MARK: Envio

    func flush() async {
        guard !isFlushing, isOnline, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false; pending.removeAll { !$0.navidrome && !$0.lastfm }; save() }

        if let client {
            for p in pending where p.navidrome {
                do {
                    try await client.scrobble(songId: p.songId, time: p.timestamp * 1000)
                    update(p.id) { $0.navidrome = false }
                } catch SubsonicError.network { break }
                  catch SubsonicError.server(let code, _) where code == 40 || code == 41 { break }
                  catch { update(p.id) { $0.navidrome = false } }   // erro permanente (ex.: faixa removida)
            }
        }

        if let lf = lastFMClient() {
            let todo = pending.filter(\.lastfm)
            for start in stride(from: 0, to: todo.count, by: 50) {
                let chunk = Array(todo[start..<min(start + 50, todo.count)])
                let tracks = chunk.map {
                    LastFMClient.Track(
                        artist: $0.artist, title: $0.title, album: $0.album,
                        albumArtist: $0.albumArtist, trackNumber: $0.trackNumber,
                        duration: $0.duration, timestamp: $0.timestamp
                    )
                }
                do {
                    try await lf.scrobble(tracks)
                    for p in chunk { update(p.id) { $0.lastfm = false } }
                    lastError = nil
                } catch let e as LastFMError {
                    if e.isRetryable { break }
                    if e.isAuthFailure { lastError = "Sessão do Last.fm expirou. Reconecte nos Ajustes."; break }
                    lastError = e.localizedDescription
                    for p in chunk { update(p.id) { $0.lastfm = false } }   // rejeitado de vez: descarta o lote
                } catch { break }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout PendingScrobble) -> Void) {
        if let i = pending.firstIndex(where: { $0.id == id }) { change(&pending[i]) }
    }

    func clearPending() { pending = []; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: file, options: .atomic) }
    }
}
