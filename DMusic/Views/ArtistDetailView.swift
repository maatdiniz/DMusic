import SwiftUI

struct ArtistDetailView: View {
    let artistId: String
    let name: String
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var coverArt: String?
    @State private var loading = true
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private var artistSource: PlaybackSource {
        .artist(Artist(id: artistId, name: name, coverArt: coverArt))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Álbuns e Participações")
                                .font(.title3.bold())
                            Spacer()
                            Text("\(albums.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .padding(.horizontal, 16)

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(album: album, badge: isParticipation(album) ? "Participação" : nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Músicas")
                                .font(.title3.bold())
                            Spacer()
                            Text("\(songs.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .padding(.horizontal, 16)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, leading: .cover, djContextSongs: songs, djContextSource: artistSource, onPlay: {
                                    player.play(songs: songs, startAt: i, source: artistSource)
                                })
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .overlay {
            if loading {
                ProgressView()
            } else if albums.isEmpty && songs.isEmpty {
                ContentUnavailableView("Nenhum álbum encontrado", systemImage: "music.mic")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .playerBottomSpace()
        .onAppear { player.visibleDetailId = "artist:\(name.lowercased())" }
        .onDisappear { if player.visibleDetailId == "artist:\(name.lowercased())" { player.visibleDetailId = nil } }
        .task(id: "\(artistId)-\(name)") {
            guard let c = auth.client else { loading = false; return }
            loading = true
            let disc = await c.artistDiscography(artistId: artistId, name: name)
            albums = disc.albums
            songs = disc.songs
            coverArt = disc.coverArt
            loading = false
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                CoverArtView(coverArt: coverArt, size: 300, cornerRadius: 38)
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            if !songs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        player.playAll(songs, source: artistSource)
                    } label: {
                        Label("Tocar Tudo", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button {
                        player.playAll(songs, shuffled: true, source: artistSource)
                    } label: {
                        Label("Aleatório", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if !albums.isEmpty { parts.append("\(albums.count) \(albums.count == 1 ? "álbum" : "álbuns")") }
        if !songs.isEmpty { parts.append("\(songs.count) \(songs.count == 1 ? "música" : "músicas")") }
        return parts.joined(separator: " • ")
    }

    private func isParticipation(_ album: Album) -> Bool {
        let primary = ArtistParser.splitNames(from: album.artist ?? "").first ?? ""
        guard !primary.isEmpty else { return false }
        return primary.caseInsensitiveCompare(name) != .orderedSame
    }
}
