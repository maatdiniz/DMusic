import SwiftUI

struct QualityBadge: View {
    let text: String
    var highlighted = false
    var accent: Color? = nil

    private var fg: Color {
        if let accent { return accent }
        return highlighted ? Color(red: 0.90, green: 0.78, blue: 0.42) : Color.white.opacity(0.72)
    }

    private var bg: Color {
        if let accent { return accent.opacity(0.13) }
        return highlighted ? Color(red: 0.90, green: 0.78, blue: 0.42).opacity(0.16) : Color.white.opacity(0.10)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }
}

/// Tag padronizada de tonalidade Camelot (apenas número e letra na cor suavizada da roda, sem borda).
struct CamelotBadge: View {
    let camelot: String

    var body: some View {
        let camColor = CamelotPalette.color(for: camelot)
        Text(camelot.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .frame(width: 30)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.09), in: Capsule())
            .foregroundStyle(camColor)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct SongRow: View {
    let song: Song
    var leading: Leading = .number
    var djContextSongs: [Song] = []
    var djContextSource: PlaybackSource? = nil
    /// Toque simples (tocar a faixa). A pressão longa abre o menu de ações.
    /// Fica antes de `onRemoveFromPlaylist` para o fechamento solto `SongRow(...) { }` ser sempre este.
    var onPlay: (() -> Void)? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    enum Leading { case number, cover }
    @Environment(AudioPlayerManager.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(FavoritesStore.self) private var favorites
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 12) {
            switch leading {
            case .number:
                Text(song.track.map(String.init) ?? "–")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 26)
            case .cover:
                CoverArtView(coverArt: song.coverArt, size: 100, cornerRadius: 4).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.subheadline.weight(.medium))
                    .foregroundStyle(player.currentSong?.id == song.id ? Color.accentColor : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let q = song.qualityText { QualityBadge(text: q, highlighted: song.isHiRes) }
                    if let mix = analysisStore.metadata(for: song.id) {
                        QualityBadge(text: "\(mix.formattedBPM) BPM")
                    }
                    let artistText = ArtistParser.displayString(for: song)
                    if !artistText.isEmpty, (leading == .cover || ArtistParser.artists(for: song).count > 1) {
                        Text(artistText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if favorites.isFavorite(song.id) {
                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Color.accentColor)
            }
            if downloads.isDownloading(song.id) {
                ProgressView().controlSize(.small)
            } else if downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").font(.footnote).foregroundStyle(Color.accentColor)
            }
            if let mix = analysisStore.metadata(for: song.id) {
                CamelotBadge(camelot: mix.camelot)
            }
            Text(formatTime(Double(song.duration ?? 0)))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .opacity(isPressed ? 0.55 : 1)
        .scaleEffect(isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.14), value: isPressed)
        .onTapGesture { onPlay?() }
        .onLongPressGesture(minimumDuration: 0.34, maximumDistance: 14) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            presentMenu()
        } onPressingChanged: { pressing in
            isPressed = pressing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Mais opções") { presentMenu() }
    }

    // MARK: Menu de ações

    private func presentMenu() {
        let song = self.song
        let player = self.player
        let favorites = self.favorites
        let downloads = self.downloads
        let isFav = favorites.isFavorite(song.id)
        let isDownloaded = downloads.isDownloaded(song.id)

        var mix: [ActionMenuItem] = []
        if djContextSongs.count > 1 {
            let context = djContextSongs
            let source = djContextSource
            mix.append(ActionMenuItem(title: djLocalLabel, subtitle: "Automix a partir desta faixa", systemImage: "waveform.path.ecg", style: .accent) {
                player.startDJMix(startingWith: song, in: context, source: source)
            })
        }
        mix.append(ActionMenuItem(title: "Mix DJ com toda a biblioteca", subtitle: "Busca todas as músicas do servidor", systemImage: "dot.radiowaves.left.and.right", style: .accent) {
            Task { await player.startFullLibraryDJMix(startingWith: song) }
        })

        let queue: [ActionMenuItem] = [
            ActionMenuItem(title: "Tocar a seguir", systemImage: "text.insert") { player.playNext(song) },
            ActionMenuItem(title: "Adicionar à fila", systemImage: "text.append") { player.addToQueue(song) },
            ActionMenuItem(title: isFav ? "Remover dos favoritos" : "Favoritar", systemImage: isFav ? "heart.slash" : "heart") { favorites.toggle(song) },
            ActionMenuItem(title: "Adicionar à playlist", systemImage: "music.note.list") { player.presentPlaylistPicker(for: [song]) },
        ]

        let goTo: [ActionMenuItem] = [
            ActionMenuItem(title: "Ir para o artista", systemImage: "music.mic") { player.navigateToSongArtist(song) },
            ActionMenuItem(title: "Ir para o álbum", systemImage: "square.stack") { player.navigateToSongAlbum(song) },
            isDownloaded
                ? ActionMenuItem(title: "Remover download", systemImage: "trash", style: .destructive) { downloads.remove(song) }
                : ActionMenuItem(title: "Baixar", systemImage: "arrow.down.circle") { Task { await downloads.download(song) } },
        ]

        var sections = [mix, queue, goTo]
        if let onRemoveFromPlaylist {
            sections.append([ActionMenuItem(title: "Remover da playlist", systemImage: "minus.circle", style: .destructive, action: onRemoveFromPlaylist)])
        }

        var badges: [String] = []
        if let q = song.qualityText { badges.append(q) }
        if let meta = analysisStore.metadata(for: song.id) { badges.append("\(meta.formattedBPM) BPM"); badges.append(meta.camelot) }

        player.actionMenu = ActionMenuRequest(
            header: ActionMenuHeader(
                title: song.title,
                subtitle: ArtistParser.displayString(for: song),
                coverArt: song.coverArt,
                badges: badges
            ),
            sections: sections
        )
    }

    private var djLocalLabel: String {
        switch djContextSource {
        case .album: return "Mix DJ neste álbum"
        case .playlist: return "Mix DJ nesta playlist"
        case .artist: return "Mix DJ neste artista"
        case .search: return "Mix DJ dos resultados"
        case .library(let raw, _):
            if raw == "Favoritas" { return "Mix DJ das favoritas" }
            if raw == "Baixadas" { return "Mix DJ das baixadas" }
            return "Mix DJ desta lista"
        case .djMix, nil:
            return "Mix DJ desta lista"
        }
    }
}

enum CamelotPalette {
    /// Paleta suavizada da Roda de Camelot (1–12), com saturação contida e contraste equilibrado no modo escuro.
    static func color(for camelot: String) -> Color {
        let trimmed = camelot.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isMajor = trimmed.hasSuffix("B")
        let number = Int(trimmed.dropLast()) ?? 0
        guard (1...12).contains(number) else {
            return Color.white.opacity(0.72)
        }
        // Roda harmônica suave (12 passos: 1 = verde-água → 3 = azul → 5 = lavanda → 7 = coral → 9 = âmbar → 11 = sálvia)
        let hues: [Double] = [
            0.46, // 1  (mint / teal)
            0.53, // 2  (aqua / slate-cyan)
            0.59, // 3  (steel blue)
            0.66, // 4  (soft indigo)
            0.74, // 5  (muted lavender)
            0.85, // 6  (dusty rose)
            0.96, // 7  (soft coral)
            0.04, // 8  (warm terracotta)
            0.09, // 9  (soft apricot)
            0.14, // 10 (warm sand/ochre)
            0.25, // 11 (sage green)
            0.37  // 12 (muted emerald)
        ]
        let hue = hues[number - 1]
        let saturation = isMajor ? 0.44 : 0.36
        let brightness = isMajor ? 0.88 : 0.80
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}
