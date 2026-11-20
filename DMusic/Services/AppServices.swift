import Foundation

/// Instâncias únicas compartilhadas por todo o app.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let auth = AuthViewModel()
    let player = AudioPlayerManager()
    let downloads = DownloadManager()
    let recents = RecentSongsCache()
    let cacheSettings = CacheSettings()
    let scrobbler = ScrobbleManager()
    let favorites = FavoritesStore()
    let analysisStore = TrackAnalysisStore()

    private var wiredServerURL: String?
    private var didWireOnce = false

    private init() {}

    /// Conecta todos os serviços ao cliente atual.
    func syncClient(force: Bool = false) {
        let currentURL = auth.client?.serverURL
        if didWireOnce, !force, currentURL == wiredServerURL { return }
        didWireOnce = true
        wiredServerURL = currentURL

        player.client = auth.client
        player.downloads = downloads
        downloads.client = auth.client
        recents.client = auth.client
        recents.settings = cacheSettings
        player.recents = recents
        scrobbler.client = auth.client
        player.scrobbler = scrobbler
        downloads.syncProtectedCovers()
        player.settings = cacheSettings
        player.applyVolumeCompensation(cacheSettings.volumeCompensation)
        player.analysisStore = analysisStore
        downloads.analysisStore = analysisStore
        recents.analysisStore = analysisStore
        downloads.analyzeExistingFiles()
        recents.analyzeExistingFiles()
        favorites.client = auth.client
        if let c = auth.client {
            let mc = MixServerClient(baseURL: MixServerClient.defaultURL(fromNavidrome: c.serverURL))
            player.mixClient = mc
            player.restoreState()
            Task {
                async let favs: Void = favorites.load()
                async let mixSync: Void = analysisStore.syncFromServer(mixClient: mc)
                _ = await (favs, mixSync)
            }
        } else {
            player.mixClient = nil
        }
    }
}
