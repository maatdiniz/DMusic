import SwiftUI

struct HomeView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(HomeViewModel.self) private var vm
    @Environment(AudioPlayerManager.self) private var player
    @State private var showSettings = false
    @State private var startingGenre = false
    @State private var genreNotice: String?

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
                    genreEntry
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
            .alert("Pool ampliado", isPresented: Binding(get: { genreNotice != nil }, set: { if !$0 { genreNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(genreNotice ?? "") }
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id, fallback: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .refreshable { if let c = auth.client { await vm.load(client: c) } }
            .task { if let c = auth.client { await vm.load(client: c) } }
        }
        .miniPlayerInset()
    }

    @ViewBuilder
    private var genreEntry: some View {
        if !vm.genres.isEmpty {
            let counts = GenreLibrary.familyCounts(vm.genres)
            VStack(alignment: .leading, spacing: 10) {
                Text("Mixes por gênero")
                    .font(.title3.bold())
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(counts.prefix(6), id: \.family) { item in
                            NavigationLink {
                                GenreInventoryView(genres: vm.genres, library: vm.genreLibrary, only: item.family)
                            } label: {
                                GenreCoverTile(family: item.family, count: item.count,
                                               onPlay: { startGenre(item.family, automix: false) },
                                               onAutomix: { startGenre(item.family, automix: true) })
                            }
                            .buttonStyle(.plain)
                        }
                        NavigationLink {
                            GenreCoversView(genres: vm.genres, library: vm.genreLibrary,
                                            onStart: { startGenre($0, automix: $1) })
                        } label: {
                            GenreAllCoverTile()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .overlay { if startingGenre { ProgressView().controlSize(.large) } }
        }
    }

    private func startGenre(_ family: GenreFamily, automix: Bool) {
        guard let client = auth.client, !startingGenre else { return }
        Task {
            startingGenre = true
            defer { startingGenre = false }
            genreNotice = await vm.genreLibrary.startMix(title: family.rawValue, family: family, automix: automix,
                                                         client: client, player: player)
        }
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
