import SwiftUI

struct AlbumDetailView: View {
    let albumId: String
    let fallback: Album
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var album: Album?
    @State private var error: String?
    @State private var showAddToPlaylist = false

    private var current: Album { album ?? fallback }
    private var songs: [Song] { album?.song ?? [] }
    private var allDownloaded: Bool { !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id) } }
    private var anyDownloading: Bool { songs.contains { downloads.isDownloading($0.id) } }

    private var headerArtistEntries: [ArtistParser.Entry] {
        let names = ArtistParser.splitNames(from: current.artist ?? "")
        if names.count == 1, let id = current.artistId {
            return [ArtistParser.Entry(id: id, name: names[0], coverArt: current.coverArt)]
        }
        if !names.isEmpty {
            return names.map { ArtistParser.Entry(id: "name:\($0)", name: $0, coverArt: current.coverArt) }
        }
        return ArtistParser.artists(for: current)
    }

    private var metadataSummary: String {
        var parts: [String] = []
        if let y = current.year { parts.append(String(y)) }
        if !songs.isEmpty {
            parts.append("\(songs.count) \(songs.count == 1 ? "faixa" : "faixas")")
            let totalSec = songs.reduce(0) { $0 + ($1.duration ?? 0) }
            if totalSec >= 60 { parts.append("\(totalSec / 60) min") }
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    CoverArtView(coverArt: current.coverArt, size: 600, cornerRadius: 12)
                        .frame(width: 136, height: 136)
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.displayName)
                            .font(.title3.bold())
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        let artistLabel = ArtistParser.displayString(from: current.artist)
                        if !artistLabel.isEmpty {
                            Button {
                                let entries = headerArtistEntries
                                if entries.count > 1 {
                                    player.artistChoices = entries
                                    player.showArtistPicker = true
                                } else if let first = entries.first {
                                    player.navigateToArtistEntry(first)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(artistLabel).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        if !metadataSummary.isEmpty {
                            Text(metadataSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    Button { player.playAll(songs, source: .album(current)) } label: {
                        Label("Tocar Tudo", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    }
                    Button { player.playAll(songs, shuffled: true, source: .album(current)) } label: {
                        Label("Aleatório", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    Button {
                        if allDownloaded { downloads.remove(songs) } else { Task { await downloads.download(songs) } }
                    } label: {
                        Group {
                            if anyDownloading { ProgressView() }
                            else { Image(systemName: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle") }
                        }
                        .foregroundStyle(allDownloaded ? Color.accentColor : .white)
                        .frame(width: 46, height: 42).background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                .buttonStyle(.plain).disabled(songs.isEmpty).padding(.horizontal, 16)

                if let error { Text(error).foregroundStyle(.red).font(.footnote) }

                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        Button { player.play(songs: songs, startAt: i, source: .album(current)) } label: {
                            SongRow(song: s, djContextSongs: songs, djContextSource: .album(current))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { for s in songs.reversed() { player.playNext(s) } } label: { Label("Tocar a seguir", systemImage: "text.insert") }
                    Button { for s in songs { player.addToQueue(s) } } label: { Label("Adicionar à fila", systemImage: "text.append") }
                    Button { showAddToPlaylist = true } label: { Label("Adicionar à playlist", systemImage: "music.note.list") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(songs.isEmpty)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) { AddToPlaylistSheet(songs: songs) }
        .playerBottomSpace()
        .onAppear { player.visibleDetailId = "album:\(albumId)" }
        .onDisappear { if player.visibleDetailId == "album:\(albumId)" { player.visibleDetailId = nil } }
        .task {
            guard let c = auth.client else { return }
            do { album = try await c.album(id: albumId) } catch { self.error = error.localizedDescription }
        }
    }
}
