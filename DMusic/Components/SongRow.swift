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

/// Selo de conteúdo explícito (tag do arquivo): quadrado com "E", ao lado do título.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.78))
            .frame(width: 14, height: 14)
            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Explícita")
    }
}

/// Indicador discreto de alta fidelidade (substitui o texto detalhado de formato/qualidade nas listas).
struct HiResTag: View {
    var body: some View {
        Text("HI-RES")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(red: 0.90, green: 0.78, blue: 0.42))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(red: 0.90, green: 0.78, blue: 0.42).opacity(0.14), in: Capsule())
            .accessibilityLabel("Alta fidelidade")
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
        HStack(spacing: 10) {
            switch leading {
            case .number:
                // Número gravado na tag da faixa (ID3), não a posição na lista
                Text(song.track.map(String.init) ?? "–")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 26)
            case .cover:
                CoverArtView(coverArt: song.coverArt, size: 100, cornerRadius: 4).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(song.title).font(.subheadline.weight(.medium))
                        .foregroundStyle(player.currentSong?.id == song.id ? Color.accentColor : .primary)
                        .lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }
                let artistText = ArtistParser.displayString(for: song)
                if !artistText.isEmpty, (leading == .cover || ArtistParser.artists(for: song).count > 1) {
                    Text(artistText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Coluna fixa à direita, sempre em duas linhas: qualidade/BPM/tom em cima; estado e duração embaixo
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if song.isHiRes { HiResTag() }
                    if let mix = analysisStore.metadata(for: song.id) {
                        QualityBadge(text: mix.formattedBPM)
                        CamelotBadge(camelot: mix.camelot)
                    }
                }
                .frame(height: 17)
                HStack(spacing: 5) {
                    if favorites.isFavorite(song.id) {
                        Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                    if downloads.isDownloading(song.id) {
                        ProgressView().controlSize(.mini)
                    } else if downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    }
                    Text(formatTime(Double(song.duration ?? 0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(height: 17)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        // Altura fixa: com ou sem linha de artista, o espaçamento entre faixas é sempre o mesmo
        .frame(height: 44)
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
                player.requestDJMix(startingWith: song, in: context, source: source)
            })
        }
        mix.append(ActionMenuItem(title: "Mix DJ com toda a biblioteca", subtitle: "Busca todas as músicas do servidor", systemImage: "dot.radiowaves.left.and.right", style: .accent) {
            player.requestDJMix(startingWith: song, in: nil, source: nil)
        })

        let queue: [ActionMenuItem] = [
            ActionMenuItem(title: "Tocar a seguir", systemImage: "text.insert") { player.playNext(song) },
            ActionMenuItem(title: "Adicionar à fila", systemImage: "text.append") { player.addToQueue(song) },
            ActionMenuItem(title: isFav ? "Remover dos favoritos" : "Favoritar", systemImage: isFav ? "heart.slash" : "heart") { favorites.toggle(song) },
            ActionMenuItem(title: "Adicionar à playlist", systemImage: "music.note.list") { player.presentPlaylistPicker(for: [song]) },
            ActionMenuItem(title: "Gêneros", subtitle: genreSubtitle, systemImage: "tag") {
                player.presentGenrePicker(title: song.title, songs: [song])
            },
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
        badges += GenreTaxonomy.familyLabels(for: [song], limit: 2)
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

    private var genreSubtitle: String {
        let labels = GenreTaxonomy.familyLabels(for: [song])
        return labels.isEmpty ? "Sem gênero — escolher para o Automix" : labels.joined(separator: ", ")
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
