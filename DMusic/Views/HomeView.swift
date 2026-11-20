import SwiftUI

struct HomeView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @State private var vm = HomeViewModel()
    @State private var showSettings = false

    var body: some View {
        @Bindable var player = player
        NavigationStack(path: $player.homePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center) {
                        Text("Início")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    if let e = vm.errorMessage {
                        Text(e).foregroundStyle(.red).padding(.horizontal, 16)
                    }
                    carousel("Adicionados recentemente", vm.newest)
                    carousel("Tocados recentemente", vm.recent)
                    carousel("Descubra", vm.random)
                }
                .padding(.vertical, 12)
            }
            .overlay { if vm.isLoading && vm.newest.isEmpty { ProgressView() } }
            .toolbar(.hidden, for: .navigationBar)
            .playerBottomSpace()
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id, fallback: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .refreshable { if let c = auth.client { await vm.load(client: c) } }
            .task { if let c = auth.client { await vm.load(client: c) } }
        }
        .miniPlayerInset()
    }

    @ViewBuilder
    private func carousel(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    HomeCategoryGridView(title: title, albums: albums)
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.title3.bold()).foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(albums.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) { AlbumCard(album: album, width: 132) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
    }
}

private struct HomeCategoryGridView: View {
    let title: String
    let albums: [Album]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .playerBottomSpace()
    }
}
