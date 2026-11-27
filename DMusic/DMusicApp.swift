import SwiftUI

@main
struct DMusicApp: App {
    init() {
        AppLogger.shared.start()
    }

    @State private var auth = AppServices.shared.auth
    @State private var home = AppServices.shared.home
    @State private var player = AppServices.shared.player
    @State private var downloads = AppServices.shared.downloads
    @State private var recents = AppServices.shared.recents
    @State private var cacheSettings = AppServices.shared.cacheSettings
    @State private var scrobbler = AppServices.shared.scrobbler
    @State private var favorites = AppServices.shared.favorites
    @State private var analysisStore = AppServices.shared.analysisStore
    @State private var transitionAudit = AppServices.shared.transitionAudit

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(home)
                .environment(player)
                .environment(downloads)
                .environment(recents)
                .environment(cacheSettings)
                .environment(scrobbler)
                .environment(favorites)
                .environment(analysisStore)
                .environment(transitionAudit)
                .tint(Color(red: 0.04, green: 0.52, blue: 1.0))
        }
    }
}
