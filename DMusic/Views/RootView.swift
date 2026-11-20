import SwiftUI

struct RootView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(RecentSongsCache.self) private var recents
    @Environment(CacheSettings.self) private var cacheSettings
    @Environment(ScrobbleManager.self) private var scrobbler
    @Environment(FavoritesStore.self) private var favorites
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if auth.isLoggedIn { MainTabView() } else { LoginView() }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await scrobbler.flush()
                    await favorites.load()
                    if let mc = player.mixClient { await analysisStore.syncFromServer(mixClient: mc) }
                }
            }
            if phase == .background { player.saveState() }
        }
        .onAppear { AppServices.shared.syncClient() }
        .onChange(of: auth.client?.serverURL) { _, _ in
            AppServices.shared.syncClient(force: true)
            if auth.client == nil { player.stop() }
        }
    }
}
