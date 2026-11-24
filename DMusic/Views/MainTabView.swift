import SwiftUI

struct MainTabView: View {
    @Environment(AudioPlayerManager.self) private var player

    var body: some View {
        @Bindable var player = player

        VStack(spacing: 0) {
            Group {
                switch player.selectedTab {
                case .home:
                    HomeView()
                case .library:
                    LibraryView()
                case .search:
                    SearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // TabBar sólida escura (sem Liquid Glass), abaixo do MiniPlayer
            HStack(spacing: 0) {
                tabButton(tab: .home, title: "Início", icon: "house.fill")
                tabButton(tab: .library, title: "Biblioteca", icon: "books.vertical.fill")
                tabButton(tab: .search, title: "Buscar", icon: "magnifyingglass")
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeInOut(duration: 0.2), value: player.currentSong?.id)
        .overlay {
            if player.showNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .animation(.spring(duration: 0.36, bounce: 0.08), value: player.showNowPlaying)
        .overlay {
            BusyIndicatorOverlay(message: player.busyMessage)
                .zIndex(20)
        }
        .actionMenuHost(player)
    }

    private func tabButton(tab: AppTab, title: String, icon: String) -> some View {
        let isSelected = (player.selectedTab == tab)
        return Button {
            if tab == .search && isSelected {
                player.searchFocusTrigger += 1
            } else {
                player.selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
