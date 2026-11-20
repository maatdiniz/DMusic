import SwiftUI

struct SearchView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @State private var vm = SearchViewModel()
    @State private var isSearchPresented = false

    var body: some View {
        @Bindable var vm = vm
        @Bindable var player = player
        NavigationStack(path: $player.searchPath) {
            List {
                if let e = vm.errorMessage { Text(e).foregroundStyle(.red) }
                if !vm.artists.isEmpty {
                    Section("Artistas") {
                        ForEach(vm.artists) { a in
                            NavigationLink(value: a) {
                                HStack(spacing: 12) {
                                    CoverArtView(coverArt: a.coverArt, size: 100, cornerRadius: 22).frame(width: 44, height: 44)
                                    Text(a.name)
                                }
                            }
                        }
                    }
                }
                if !vm.albums.isEmpty {
                    Section("Álbuns") {
                        ForEach(vm.albums) { al in
                            NavigationLink(value: al) {
                                HStack(spacing: 12) {
                                    CoverArtView(coverArt: al.coverArt, size: 100, cornerRadius: 4).frame(width: 44, height: 44)
                                    VStack(alignment: .leading) {
                                        Text(al.displayName).lineLimit(1)
                                        Text(al.artist ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !vm.songs.isEmpty {
                    Section("Músicas") {
                        ForEach(Array(vm.songs.enumerated()), id: \.element.id) { i, s in
                            Button { player.play(songs: vm.songs, startAt: i, source: .search(query: vm.query)) } label: {
                                SongRow(song: s, leading: .cover, djContextSongs: vm.songs, djContextSource: .search(query: vm.query))
                            }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if vm.isLoading { ProgressView() }
                else if !vm.hasResults && vm.query.isEmpty {
                    ContentUnavailableView("Buscar", systemImage: "magnifyingglass", description: Text("Artistas, álbuns e músicas"))
                } else if !vm.hasResults && vm.errorMessage == nil {
                    ContentUnavailableView.search(text: vm.query)
                }
            }
            .navigationTitle("Buscar")
            .playerBottomSpace()
            .searchable(
                text: $vm.query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Artistas, álbuns, músicas"
            )
            .onChange(of: player.searchFocusTrigger) { _, _ in
                isSearchPresented = true
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id, fallback: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .onChange(of: player.requestedSearchQuery) { _, q in
                if let q { vm.query = q; player.requestedSearchQuery = nil }
            }
            .task(id: vm.query) { if let c = auth.client { await vm.search(client: c) } }
        }
        .miniPlayerInset()
    }
}
