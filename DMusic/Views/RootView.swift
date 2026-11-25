import SwiftUI

struct RootView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(HomeViewModel.self) private var home
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(RecentSongsCache.self) private var recents
    @Environment(CacheSettings.self) private var cacheSettings
    @Environment(ScrobbleManager.self) private var scrobbler
    @Environment(FavoritesStore.self) private var favorites
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSplash = true

    var body: some View {
        ZStack {
            Group {
                if auth.isLoggedIn { MainTabView() } else { LoginView() }
            }

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(100)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await scrobbler.flush()
                    await favorites.load()
                    await analysisStore.syncFromServerIfStale(mixClient: player.mixClient)
                }
            }
            if phase == .background { player.saveState(blocking: true) }
        }
        .task {
            AppServices.shared.syncClient()
            guard showSplash else { return }

            async let minimumSplashDuration: Void = {
                try? await Task.sleep(for: .milliseconds(550))
            }()

            if let client = auth.client {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await home.loadIfNeeded(client: client)
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(2400))
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }

            await minimumSplashDuration
            withAnimation(.easeOut(duration: 0.36)) {
                showSplash = false
            }
        }
        .onChange(of: auth.client?.serverURL) { _, _ in
            AppServices.shared.syncClient(force: true)
            if auth.client == nil { player.stop() }
        }
    }
}
