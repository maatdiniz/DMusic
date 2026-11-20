import SwiftUI

struct LibraryView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(RecentSongsCache.self) private var recents
    @Environment(FavoritesStore.self) private var favorites
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @State private var vm = LibraryViewModel()
    @State private var loadingFullLibrary = false
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        @Bindable var vm = vm
        @Bindable var player = player
        NavigationStack(path: $player.libraryPath) {
            ScrollView {
                VStack(spacing: 16) {
                    chips
                    if let e = vm.errorMessage { Text(e).foregroundStyle(.red).padding(.horizontal) }
                    content
                }
                .padding(.vertical)
            }
            .overlay { if vm.isLoading && isEmptyLoading { ProgressView() } }
            .navigationTitle("Biblioteca")
            .playerBottomSpace()
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id, fallback: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .onChange(of: player.requestedLibrarySection) { _, sec in
                if let sec { vm.section = sec; player.requestedLibrarySection = nil }
            }
            .task(id: vm.section) {
                guard let c = auth.client else { return }
                if vm.section == .favorites { await favorites.load() }
                await vm.load(client: c)
            }
        }
        .miniPlayerInset()
    }

    private var isEmptyLoading: Bool {
        switch vm.section {
        case .albums: return vm.albums.isEmpty
        case .artists: return vm.artists.isEmpty
        case .songs: return vm.songs.isEmpty
        case .playlists: return vm.playlists.isEmpty
        default: return false
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { s in
                    Button { vm.section = s } label: {
                        Text(s.rawValue).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(vm.section == s ? Color.accentColor : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.section {
        case .albums:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                ForEach(vm.albums) { album in
                    NavigationLink(value: album) { AlbumCard(album: album) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        case .artists:
            LazyVStack(spacing: 0) {
                ForEach(vm.artists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            CoverArtView(coverArt: artist.coverArt, size: 100, cornerRadius: 28).frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(artist.name)
                                if let c = artist.albumCount { Text("\(c) álbuns").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.horizontal).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }
        case .songs:
            songsList
        case .playlists:
            LazyVStack(spacing: 0) {
                ForEach(vm.playlists) { pl in
                    NavigationLink(value: pl) {
                        HStack(spacing: 12) {
                            CoverArtView(coverArt: pl.coverArt, size: 100).frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(pl.name)
                                Text("\(pl.songCount ?? 0) músicas").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.horizontal).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                try? await auth.client?.deletePlaylist(id: pl.id)
                                if let c = auth.client { await vm.refreshPlaylists(client: c) }
                            }
                        } label: { Label("Excluir playlist", systemImage: "trash") }
                    }
                }
            }
        case .favorites:
            if favorites.songs.isEmpty {
                ContentUnavailableView("Sem favoritas", systemImage: "heart",
                    description: Text("Toque no coração no player ou segure uma faixa para favoritar."))
            } else {
                let favSource = PlaybackSource.library(sectionRaw: LibrarySection.favorites.rawValue, title: "Favoritas")
                playButtons(favorites.songs, source: favSource)
                songRows(favorites.songs, source: favSource)
            }
        case .downloads:
            if downloads.songs.isEmpty && recents.songs.isEmpty {
                ContentUnavailableView("Nada salvo", systemImage: "arrow.down.circle",
                    description: Text("Segure uma faixa ou use o botão de download no álbum."))
            }
            if !downloads.songs.isEmpty {
                offlineList("Baixadas", downloads.songs, source: .library(sectionRaw: LibrarySection.downloads.rawValue, title: "Baixadas"))
            }
            if !recents.songs.isEmpty {
                offlineList("Tocadas recentemente (cache)", recents.songs, source: .library(sectionRaw: LibrarySection.downloads.rawValue, title: "Tocadas recentemente"))
            }
        }
    }

    private var songsList: some View {
        let songsSource = PlaybackSource.library(sectionRaw: LibrarySection.songs.rawValue, title: "Todas as Músicas")
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    guard !loadingFullLibrary, let c = auth.client else {
                        player.playAll(vm.songs, source: songsSource)
                        return
                    }
                    loadingFullLibrary = true
                    Task {
                        let all = await vm.loadAllSongs(client: c)
                        loadingFullLibrary = false
                        if !all.isEmpty {
                            player.playAll(all, source: songsSource)
                        }
                    }
                } label: {
                    Label("Tocar", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 42)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white).fontWeight(.semibold)
                }
                Button {
                    guard !loadingFullLibrary, let c = auth.client else { return }
                    loadingFullLibrary = true
                    Task {
                        let all = await vm.loadAllSongs(client: c)
                        loadingFullLibrary = false
                        player.automixEnabled = false
                        if !all.isEmpty {
                            player.playAll(all, shuffled: true, source: songsSource)
                        } else if let s = try? await c.randomSongs(size: 100), !s.isEmpty {
                            player.playAll(s, shuffled: true, source: songsSource)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shuffle")
                        Text("Aleatório")
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }

                Button {
                    guard !loadingFullLibrary, let c = auth.client else { return }
                    loadingFullLibrary = true
                    Task {
                        async let allTask = vm.loadAllSongs(client: c)
                        async let syncTask: Void = analysisStore.syncFromServerIfStale(mixClient: player.mixClient)
                        let all = await allTask
                        _ = await syncTask
                        loadingFullLibrary = false
                        player.automixEnabled = true
                        if !all.isEmpty {
                            player.playAll(all, shuffled: true, source: songsSource)
                        } else if let s = try? await c.randomSongs(size: 100), !s.isEmpty {
                            player.playAll(s, shuffled: true, source: songsSource)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if loadingFullLibrary {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(loadingFullLibrary ? "..." : "DJ")
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(Color.white.opacity(0.16), in: Capsule())
                }
            }
            .buttonStyle(.plain).disabled(vm.songs.isEmpty || loadingFullLibrary).padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(Array(vm.songs.enumerated()), id: \.element.id) { i, s in
                    Button {
                        if player.shuffle, !vm.hasLoadedAllSongs, let c = auth.client {
                            guard !loadingFullLibrary else { return }
                            loadingFullLibrary = true
                            Task {
                                async let allTask = vm.loadAllSongs(client: c)
                                async let syncTask: Void = analysisStore.syncFromServerIfStale(mixClient: player.mixClient)
                                let all = await allTask
                                _ = await syncTask
                                loadingFullLibrary = false
                                let idx = all.firstIndex(where: { $0.id == s.id }) ?? i
                                player.play(songs: all, startAt: idx, source: songsSource)
                            }
                        } else {
                            player.play(songs: vm.songs, startAt: i, source: songsSource)
                        }
                    } label: {
                        SongRow(song: s, leading: .cover, djContextSongs: vm.songs, djContextSource: songsSource).padding(.horizontal).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .task { if let c = auth.client { await vm.loadMoreIfNeeded(current: s, client: c) } }
                }
            }
        }
    }

    @ViewBuilder
    private func playButtons(_ songs: [Song], source: PlaybackSource) -> some View {
        HStack(spacing: 10) {
            Button { player.playAll(songs, source: source) } label: {
                Label("Tocar", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 42)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white).fontWeight(.semibold)
            }
            Button { player.playAll(songs, shuffled: true, source: source) } label: {
                Label("Aleatório", systemImage: "shuffle").frame(maxWidth: .infinity).frame(height: 42)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
        }.buttonStyle(.plain).padding(.horizontal)
    }

    private func songRows(_ songs: [Song], source: PlaybackSource) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                Button { player.play(songs: songs, startAt: i, source: source) } label: {
                    SongRow(song: s, leading: .cover, djContextSongs: songs, djContextSource: source).padding(.horizontal).padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func offlineList(_ title: String, _ songs: [Song], source: PlaybackSource) -> some View {
        Text(title).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
        songRows(songs, source: source)
    }
}
