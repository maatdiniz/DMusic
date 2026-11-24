import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @State private var songs: [Song] = []
    @State private var loading = true
    private var allDownloaded: Bool { !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverArtView(coverArt: playlist.coverArt, size: 600, cornerRadius: 12)
                    .frame(maxWidth: 260).shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                HStack(spacing: 8) {
                    Button { player.playAll(songs, source: .playlist(playlist)) } label: {
                        Label("Tocar", systemImage: "play.fill").font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    }
                    Button {
                        player.automixEnabled = false
                        player.playAll(songs, shuffled: true, source: .playlist(playlist))
                    } label: {
                        Label("Aleatório", systemImage: "shuffle").font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    Button {
                        Task {
                            await analysisStore.syncFromServerIfStale(mixClient: player.mixClient)
                            player.automixEnabled = true
                            player.playAll(songs, shuffled: true, source: .playlist(playlist))
                        }
                    } label: {
                        Label("DJ", systemImage: "waveform.path.ecg").font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                }
                .buttonStyle(.plain).disabled(songs.isEmpty).padding(.horizontal)
                Button {
                    if allDownloaded { downloads.remove(songs) } else { Task { await downloads.download(songs) } }
                } label: {
                    Label(allDownloaded ? "Remover downloads" : "Baixar playlist",
                          systemImage: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain).disabled(songs.isEmpty).padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        SongRow(
                            song: s,
                            leading: .cover,
                            djContextSongs: songs,
                            djContextSource: .playlist(playlist),
                            onPlay: { player.play(songs: songs, startAt: i, source: .playlist(playlist)) },
                            onRemoveFromPlaylist: {
                                Task {
                                    guard let c = auth.client else { return }
                                    try? await c.removeFromPlaylist(id: playlist.id, index: i)
                                    songs = (try? await c.playlist(id: playlist.id).entry) ?? songs
                                }
                            }
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }
            }.padding(.top, 8)
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .playerBottomSpace()
        .onAppear { player.visibleDetailId = "playlist:\(playlist.id)" }
        .onDisappear { if player.visibleDetailId == "playlist:\(playlist.id)" { player.visibleDetailId = nil } }
        .task {
            if let c = auth.client { songs = (try? await c.playlist(id: playlist.id).entry) ?? [] }
            loading = false
        }
    }
}
