import SwiftUI
import AVKit

struct NowPlayingView: View {
    @Environment(AudioPlayerManager.self) private var player
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var showAutomixStudio = false
    /// Altura livre entre a base da capa e o título da música (para centralizar o BPM das capas na mixagem).
    @State private var stageGap: CGFloat = 60
    @State private var dismissDragY: CGFloat = 0
    @AppStorage("nowplaying_spectrogram_mode") private var showSpectrogram = false
    @Environment(FavoritesStore.self) private var favorites
    @Environment(TrackAnalysisStore.self) private var analysisStore

    var body: some View {
        ZStack {
            ambientBackground

            VStack(spacing: 14) {
                Capsule()
                    .fill(.white.opacity(0.32))
                    .frame(width: 38, height: 5)
                    .padding(.top, 6)
                    .onTapGesture { player.showNowPlaying = false }

                topBar

                Spacer(minLength: 0)

                if showSpectrogram {
                    // Borda a borda (ignora o recuo lateral de 20 pt), sem cantos arredondados nem sombra
                    ScrollingSpectrogramView()
                        .padding(.horizontal, -20)
                        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 440)
                } else {
                    CoverStageView(
                        stageMode: player.coverStageMode,
                        currentCoverArt: player.currentSong?.coverArt,
                        coverArtA: player.stageCoverArtA,
                        coverArtB: player.stageCoverArtB,
                        rateA: player.stageRateA,
                        bpmA: player.liveAnimatedBPM ?? player.stageBPMA,
                        bpmB: player.stageBPMB,
                        liveBPMTrend: player.liveBPMTrend,
                        isPlaying: player.isPlaying,
                        onSettlingFinished: { player.finishCoverStageSettling() },
                        onSwipeNext: { player.next() },
                        onSwipePrevious: { player.previous() },
                        chipGap: stageGap
                    )
                }

                Spacer(minLength: 0)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: StageGapKey.self, value: geo.size.height)
                    })

                trackHeader

                NowPlayingScrubberView(onOpenAutomixStudio: { showAutomixStudio = true })

                transportControls

                bottomDock
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showAddToPlaylist) {
            if let s = player.currentSong { AddToPlaylistSheet(songs: [s]) }
        }
        .onPreferenceChange(StageGapKey.self) { stageGap = $0 }
        .sheet(isPresented: $showAutomixStudio) {
            AutomixStudioSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .offset(y: dismissDragY)
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { v in
                    if v.translation.height > 0 {
                        dismissDragY = v.translation.height
                    }
                }
                .onEnded { v in
                    if v.translation.height > 110 || v.predictedEndTranslation.height > 220 {
                        withAnimation(.easeOut(duration: 0.22)) {
                            dismissDragY = 600
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            player.showNowPlaying = false
                            dismissDragY = 0
                        }
                    } else {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            dismissDragY = 0
                        }
                    }
                }
        )
    }

    // MARK: - Subviews

    private var ambientBackground: some View {
        AmbientCoverBackground(coverArt: player.currentSong?.coverArt)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { player.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if let source = player.effectivePlaybackSource {
                let headerContent = VStack(spacing: 1) {
                    Text(source.headerLabel)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(source.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        if source.isNavigable {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

                if source.isNavigable {
                    Button { player.navigateToSource() } label: {
                        headerContent
                    }
                    .buttonStyle(.plain)
                } else {
                    headerContent
                }
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSpectrogram.toggle()
                }
            } label: {
                Image(systemName: showSpectrogram ? "photo.fill" : "waveform")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(showSpectrogram ? Color(red: 0.25, green: 0.78, blue: 1.0) : .white)
                    .frame(width: 36, height: 36)
                    .background(
                        (showSpectrogram ? Color(red: 0.25, green: 0.78, blue: 1.0).opacity(0.20) : Color.white.opacity(0.1)),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showSpectrogram ? "Mostrar capa" : "Mostrar espectrograma Rekordbox")

            Button {
                presentPlayerMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mais opções")
        }
    }

    /// Menu "…" do player no painel padrão do app (navegação, playlist, estúdio e timer de sono).
    private func presentPlayerMenu() {
        let player = self.player
        var go: [ActionMenuItem] = []
        if let song = player.currentSong {
            let entries = ArtistParser.artists(for: song)
            if entries.count > 1 {
                go.append(ActionMenuItem(
                    title: "Ir para o artista",
                    systemImage: "music.mic",
                    children: entries.map { entry in
                        ActionMenuItem(title: entry.name, systemImage: "person.fill") { player.navigateToArtistEntry(entry) }
                    }
                ))
            } else {
                go.append(ActionMenuItem(title: "Ir para o artista", systemImage: "music.mic") { player.navigateToSongArtist(song) })
            }
            go.append(ActionMenuItem(title: "Ir para o álbum", systemImage: "square.stack") { player.navigateToSongAlbum(song) })
        }
        if let source = player.effectivePlaybackSource {
            go.append(ActionMenuItem(title: "Ir para \(source.title)", systemImage: "arrow.turn.up.right") { player.navigateToSource() })
        }

        var tools: [ActionMenuItem] = []
        if let song = player.currentSong {
            tools.append(ActionMenuItem(title: "Adicionar à playlist", systemImage: "music.note.list") { player.presentPlaylistPicker(for: [song]) })
            let genreLabels = GenreTaxonomy.familyLabels(for: [song])
            tools.append(ActionMenuItem(title: "Gêneros", subtitle: genreLabels.isEmpty ? "Sem gênero — escolher para o Automix" : genreLabels.joined(separator: ", "), systemImage: "tag") {
                player.presentGenrePicker(title: song.title, songs: [song])
            })
        }
        tools.append(ActionMenuItem(title: "Estúdio de mixagem", subtitle: "EQ, filtros e curvas do Automix", systemImage: "slider.horizontal.3", style: .accent) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                showAutomixStudio = true
            }
        })

        let sleepActive = player.sleepEnd != nil || player.sleepAtEndOfTrack
        let sleepOptions: [Int] = [15, 30, 45, 60]
        var sleepItems: [ActionMenuItem] = sleepOptions.map { minutes in
            ActionMenuItem(title: "\(minutes) minutos", systemImage: "moon.zzz") { player.setSleepTimer(minutes: minutes) }
        }
        sleepItems.append(ActionMenuItem(title: "Ao fim da faixa", systemImage: "music.note") { player.sleepAfterCurrentTrack() })
        if sleepActive {
            sleepItems.append(ActionMenuItem(title: "Desativar", systemImage: "xmark.circle", style: .destructive) { player.cancelSleep() })
        }
        let sleep = [ActionMenuItem(
            title: "Dormir",
            subtitle: sleepActive ? sleepLabel : nil,
            systemImage: "moon.zzz.fill",
            children: sleepItems
        )]

        var header: ActionMenuHeader?
        if let song = player.currentSong {
            header = ActionMenuHeader(title: song.title, subtitle: ArtistParser.displayString(for: song), coverArt: song.coverArt)
        }
        player.actionMenu = ActionMenuRequest(header: header, sections: [go, tools, sleep].filter { !$0.isEmpty })
    }

    private var trackHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let song = player.currentSong {
                    Button {
                        player.navigateToSongAlbum(song)
                    } label: {
                        MarqueeText(text: titleWithAlbum(for: song), alignment: .leading)
                            .id(song.id)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    let artistDisplay = ArtistParser.displayString(for: song)
                    HStack(spacing: 8) {
                        if !artistDisplay.isEmpty {
                            Button { player.navigateToSongArtist(song) } label: {
                                HStack(spacing: 5) {
                                    Text(artistDisplay)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(.white.opacity(0.75))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 4)

                        if let meta = analysisStore.metadata(for: song.id) {
                            // O BPM ao lado do nome da faixa é SEMPRE o BPM fixo original da faixa;
                            // o único BPM que altera ao vivo na mudança de ritmo aparece no Palco / Espectrograma.
                            TrackMixBadgeView(mix: meta)
                                .layoutPriority(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let song = player.currentSong {
                let fav = favorites.isFavorite(song.id)
                Button { favorites.toggle(song) } label: {
                    Image(systemName: fav ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(fav ? .white : .white.opacity(0.75))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transportControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(player.shuffle ? .white : .white.opacity(0.45))
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .opacity(player.shuffle ? 1 : 0)
                }
                .frame(width: 40, height: 40)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                DJControllerPlayPauseButton(isPlaying: player.isPlaying)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                VStack(spacing: 3) {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.45) : .white)
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .opacity(player.repeatMode == .off ? 0 : 1)
                }
                .frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
    }

    private var bottomDock: some View {
        HStack(spacing: 12) {
            AirPlayRouteButton().styled()

            Spacer(minLength: 8)

            fileInfo

            Spacer(minLength: 8)

            Button { showQueue = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 38, height: 36)
                    if player.priorityCount > 0 {
                        Text("\(player.priorityCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.white, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    /// Tipo do arquivo e qualidade da faixa que está tocando: `FLAC  24-bit / 96 kHz` e, embaixo, `HI-RES` em texto simples.
    @ViewBuilder
    private var fileInfo: some View {
        if let song = player.currentSong, let suffix = song.suffix, !suffix.isEmpty {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    QualityBadge(text: suffix.uppercased())
                    if let detail = Self.qualityDetail(for: song) {
                        Text(detail)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                if song.isHiRes {
                    Text("HI-RES")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.90, green: 0.78, blue: 0.42))
                }
            }
            .multilineTextAlignment(.center)
            .id(song.id)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Arquivo \(suffix.uppercased())"
                + (Self.qualityDetail(for: song).map { ", \($0)" } ?? "")
                + (song.isHiRes ? ", alta resolução" : ""))
        }
    }

    private static func qualityDetail(for song: Song) -> String? {
        if let depth = song.bitDepth, depth > 0, let rate = song.samplingRate, rate > 0 {
            let khz = Double(rate) / 1000
            let khzText = khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz))" : String(format: "%.1f", khz)
            return "\(depth)-bit / \(khzText) kHz"
        }
        if let kbps = song.bitRate, kbps > 0 { return "\(kbps) kbps" }
        return nil
    }

    private func titleWithAlbum(for song: Song) -> String {
        if let album = song.album, !album.isEmpty {
            return "\(song.title) - \(album)"
        }
        if case .album(let a) = player.effectivePlaybackSource {
            return "\(song.title) - \(a.displayName)"
        }
        return song.title
    }

    private var sleepLabel: String {
        if player.sleepAtEndOfTrack { return "Fim da faixa" }
        if let end = player.sleepEnd { return end.formatted(date: .omitted, time: .shortened) }
        return "Dormir"
    }
}

/// Badge do cabeçalho da faixa que exibe o BPM original fixo e a tonalidade padronizada na paleta suavizada de Camelot.
private struct TrackMixBadgeView: View {
    let mix: TrackMixMetadata

    var body: some View {
        HStack(spacing: 4) {
            QualityBadge(text: "\(mix.formattedBPM) BPM")
            if !mix.camelot.isEmpty {
                CamelotBadge(camelot: mix.camelot)
            }
        }
    }
}

/// Slider de progresso inteligente para o modo DJ:
/// - Limita o alcance total até antes de começar a transição (`maxTime = mixStartSec`)
/// - Colore apenas o trecho final do trilho correspondente à variação de BPM da Faixa A (`rampStartSec ... mixStartSec`)
///   com Laranja/Âmbar (aumentando BPM) ou Azul Ciano (reduzindo BPM), mantendo o progresso percorrido em branco.
private struct DJScrubberSlider: View {
    @Binding var value: Double
    let maxTime: Double
    let currentTime: Double
    @Binding var isDragging: Bool
    let plan: TransitionPlan?
    let onEditingChanged: (Bool) -> Void

    private struct SliderRampZone {
        let startFrac: CGFloat
        let holdStartFrac: CGFloat?
        let color: Color
    }

    private var safeMax: Double { max(maxTime, 1.0) }
    private var displayValue: Double {
        min(max(isDragging ? value : currentTime, 0.0), safeMax)
    }
    private var progressFraction: CGFloat {
        CGFloat(min(max(displayValue / safeMax, 0.0), 1.0))
    }

    private var rampZone: SliderRampZone? {
        guard let plan else { return nil }
        let mixStart = plan.trackA.mixStartSec
        guard mixStart > 4.0 else { return nil }
        let rateA = plan.sync.targetRateA
        let hasRateChange = abs(rateA - 1.0) >= 0.003 && plan.sync.rampDurationSec >= 0.25 && plan.TrackARampValid
        if hasRateChange {
            let rampStart = min(max(0.0, plan.trackA.rampStartSec), mixStart)
            let rampEnd = min(mixStart, rampStart + plan.sync.rampDurationSec)
            let zoneColor = rateA > 1.0
                ? Color(red: 0.72, green: 0.36, blue: 1.0)   // Roxo = aumentando BPM
                : Color(red: 1.0, green: 0.34, blue: 0.38)   // Coral = reduzindo BPM
            let startFrac = CGFloat(min(max(rampStart / safeMax, 0.0), 0.96))
            let holdFrac: CGFloat? = (rampEnd < mixStart - 0.5)
                ? CGFloat(min(max(rampEnd / safeMax, Double(startFrac) + 0.01), 0.98))
                : nil
            return SliderRampZone(startFrac: startFrac, holdStartFrac: holdFrac, color: zoneColor)
        }
        // Quando não altera a velocidade da Faixa A, mantém a barra 100% normal sem cores extras
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let trackH: CGFloat = isDragging ? 7 : 5
            let thumbSize: CGFloat = isDragging ? 16 : 12
            let fillW = w * progressFraction
            let zone = rampZone

            ZStack(alignment: .leading) {
                // Trilho base + trechos de rampa/hold de BPM + progresso branco, todos recortados no Capsule exato
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: w, height: trackH)

                    if let zone {
                        let zoneX = w * zone.startFrac
                        if let holdFrac = zone.holdStartFrac {
                            let holdX = w * holdFrac
                            let rampW = max(0, holdX - zoneX)
                            let holdW = max(0, w - holdX)

                            Rectangle()
                                .fill(zone.color.opacity(0.70))
                                .frame(width: rampW, height: trackH)
                                .offset(x: zoneX)

                            Rectangle()
                                .fill(Color.white.opacity(0.45))
                                .frame(width: holdW, height: trackH)
                                .offset(x: holdX)
                        } else {
                            let zoneW = max(0, w - zoneX)
                            Rectangle()
                                .fill(zone.color.opacity(0.70))
                                .frame(width: zoneW, height: trackH)
                                .offset(x: zoneX)
                        }
                    }

                    // Progresso percorrido sempre em branco
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: max(0, fillW), height: trackH)
                }
                .frame(width: w, height: trackH)
                .clipShape(Capsule(style: .continuous))

                // Thumb (bolinha do slider) sempre branco
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: min(max(0, fillW - thumbSize / 2), w - thumbSize))
            }
            .frame(width: w, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let ratio = min(max(0.0, Double(drag.location.x / w)), 1.0)
                        value = ratio * safeMax
                    }
                    .onEnded { drag in
                        let ratio = min(max(0.0, Double(drag.location.x / w)), 1.0)
                        value = ratio * safeMax
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

private extension TransitionPlan {
    var TrackARampValid: Bool {
        trackA.rampStartSec < trackA.mixStartSec - 0.1
    }
}

/// Badge curto, discreto e codificado por cores para indicar estado do Automix:
/// - `armed`: azul discreto (SYNC MM:SS ↑/↓)
/// - `syncUp`: âmbar/laranja vibrante (SYNC ↑ aumentando BPM)
/// - `syncDown`: ciano/azul elétrico (SYNC ↓ reduzindo BPM)
/// - `syncSteady`: verde esmeralda (SYNC = BPM cravado)
/// - `mixOverlap`: verde neon DJ (MIX • EQ)
/// - `mixThreeBand`: roxo/magenta neon (MIX • 3B)
/// - `mixQuickCut`: rosa/vermelho punch (MIX • CORTE)
/// - `mixFilterWash`: turquesa espacial (MIX • FX / WASH)
/// - `mixFade`: dourado suave (MIX • FADE)
private struct AutomixPillBadgeView: View {
    let badge: AutomixIndicatorBadge

    private var color: Color {
        switch badge.kind {
        case .armed:
            return Color(red: 0.35, green: 0.78, blue: 1.0)
        case .syncUp:
            return Color(red: 1.0, green: 0.62, blue: 0.12)
        case .syncDown:
            return Color(red: 0.18, green: 0.78, blue: 1.0)
        case .syncSteady:
            return Color(red: 0.20, green: 0.90, blue: 0.55)
        case .mixOverlap:
            return Color(red: 0.12, green: 0.88, blue: 0.42)
        case .mixThreeBand:
            return Color(red: 0.74, green: 0.38, blue: 1.0)
        case .mixQuickCut:
            return Color(red: 1.0, green: 0.27, blue: 0.52)
        case .mixFilterWash:
            return Color(red: 0.15, green: 0.92, blue: 0.85)
        case .mixFade:
            return Color(red: 0.96, green: 0.78, blue: 0.25)
        }
    }

    private var isActivePhase: Bool {
        badge.kind != .armed
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = badge.icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .black))
            }
            Text(badge.text)
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .tracking(0.4)
        }
        .foregroundStyle(isActivePhase ? Color.black : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(isActivePhase ? color : color.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(isActivePhase ? 0.9 : 0.45), lineWidth: 0.8)
        )
        .shadow(color: isActivePhase ? color.opacity(0.55) : .clear, radius: 6, y: 0)
        .animation(.easeInOut(duration: 0.25), value: badge)
    }
}

/// Botão Play/Pause estilo Mesa Controladora de DJ (Pioneer CDJ / Spotify DJ Mode)
/// com anel de LED verde iluminado quando aceso (`isPlaying == true`) e LED apagado quando em pausa.
private struct DJControllerPlayPauseButton: View {
    let isPlaying: Bool

    private let ledGreen = Color(red: 0.12, green: 0.84, blue: 0.38)

    var body: some View {
        ZStack {
            // Glow externo difuso do LED verde quando aceso
            Circle()
                .fill(ledGreen.opacity(isPlaying ? 0.28 : 0.0))
                .frame(width: 78, height: 78)
                .blur(radius: 10)

            // Base metálica escura do botão da controladora
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.22),
                            Color(white: 0.11),
                            Color(white: 0.06)
                        ],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: 56
                    )
                )
                .frame(width: 68, height: 68)
                .shadow(color: .black.opacity(0.6), radius: 10, y: 5)

            // Friso interno escovado
            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .frame(width: 58, height: 58)

            // Anel de LED verde em volta (aceso com brilho neon ou apagado fosco)
            Circle()
                .strokeBorder(
                    isPlaying
                        ? ledGreen
                        : Color(red: 0.12, green: 0.32, blue: 0.18).opacity(0.45),
                    lineWidth: isPlaying ? 3.2 : 2.0
                )
                .frame(width: 66, height: 66)
                .shadow(color: isPlaying ? ledGreen.opacity(0.9) : .clear, radius: 8, x: 0, y: 0)
                .shadow(color: isPlaying ? ledGreen.opacity(0.5) : .clear, radius: 14, x: 0, y: 0)

            // Ícone Play / Pause central
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(isPlaying ? ledGreen : Color.white.opacity(0.82))
                .offset(x: isPlaying ? 0 : 1.5)
                .shadow(color: isPlaying ? ledGreen.opacity(0.65) : .clear, radius: 6)
        }
        .frame(width: 74, height: 74)
        .animation(.easeInOut(duration: 0.22), value: isPlaying)
    }
}

private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

extension AirPlayRouteButton {
    func styled() -> some View {
        self.frame(width: 36, height: 36)
            .background(Color.white.opacity(0.1), in: Circle())
    }
}

private struct MarqueeText: View {
    let text: String
    var alignment: Alignment = .leading
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth && containerWidth > 0 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: overflows ? .leading : alignment) {
                Text(text)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }

                label
                    .offset(x: overflows ? offset : 0)
            }
            .frame(width: width, height: geo.size.height, alignment: overflows ? .leading : alignment)
            .clipped()
            .onAppear {
                containerWidth = width
                resetOffsetImmediately()
            }
            .onChange(of: width) { _, w in containerWidth = w }
            .onChange(of: text) { _, _ in resetOffsetImmediately() }
            .task(id: "\(text)-\(Int(textWidth))-\(Int(containerWidth))") {
                resetOffsetImmediately()
                let maxScroll = textWidth - containerWidth
                guard maxScroll > 0, containerWidth > 0 else { return }
                let duration = max(Double(maxScroll) / 35.0, 2.2)
                let pauseMs = 1500
                let travelMs = Int(duration * 1000) + 50

                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(pauseMs))
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: duration)) {
                        offset = -maxScroll
                    }
                    try? await Task.sleep(for: .milliseconds(travelMs + 1000))
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: duration)) {
                        offset = 0
                    }
                    try? await Task.sleep(for: .milliseconds(travelMs))
                }
            }
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private func resetOffsetImmediately() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { offset = 0 }
    }

    private var label: some View {
        Text(text)
            .font(.title3.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.primary)
    }
}

struct AutomixStudioSheet: View {
    @Environment(AudioPlayerManager.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var p = player
        NavigationStack {
            VStack(spacing: 0) {
                DarkSheetHeader(title: "Estúdio Automix") { dismiss() }

                ScrollView {
                    VStack(spacing: 18) {
                        DarkCardSection("Status da Mixagem") {
                            DarkToggleRow(title: "Automix Ativo", isOn: $p.automixEnabled)
                            if let hint = player.preparedMixHint {
                                DarkCardDivider()
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 1.0))
                                    Text(hint)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 1.0))
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                            }
                            DarkCardDivider()
                            DarkNavRow(
                                title: "Log do Sistema e Ordem do Aleatório",
                                icon: "doc.text.magnifyingglass"
                            ) {
                                AutomixLogsView()
                            }
                            DarkCardDivider()
                            DarkNavRow(
                                title: "Guia de Cores e Mixagens",
                                icon: "book.pages"
                            ) {
                                AutomixGuideView()
                            }
                        }

                        DarkCardSection(
                            "Duração da Transição",
                            footer: "Escolha 2, 4, 8 ou 16 compassos, ou deixe a IA decidir conforme o fraseado da música."
                        ) {
                            DarkMenuPickerRow(
                                title: "Duração",
                                selection: $p.automixDurationChoice,
                                valueLabel: p.automixDurationChoice.title,
                                options: AutomixDurationChoice.allCases.map { ($0, $0.title) }
                            )
                        }

                        DarkCardSection(
                            "Curva de Volume (Sobreposição)",
                            footer: "O modo padrão 'Sobrepor' mantém as duas músicas batendo juntas com pressão sem derrubar o volume no meio."
                        ) {
                            DarkMenuPickerRow(
                                title: "Volume",
                                selection: $p.automixVolumeCurve,
                                valueLabel: p.automixVolumeCurve.title,
                                options: AutomixVolumeCurve.allCases.map { ($0, $0.title) }
                            )
                        }

                        DarkCardSection(
                            "EQ no Meio da Transição",
                            footer: "Controla como os graves (185 Hz), médios (1 kHz) e agudos (4.2 kHz) trocam entre a música que sai e a que entra."
                        ) {
                            DarkMenuPickerRow(
                                title: "Equalização (EQ)",
                                selection: $p.automixEQStyle,
                                valueLabel: p.automixEQStyle.title,
                                options: AutomixEQStyle.allCases.map { ($0, $0.title) }
                            )
                        }

                        DarkCardSection(
                            "Filtros de Mixer DJ & Efeitos",
                            footer: "Aplica varredura de filtro passa-baixa/passa-alta na entrada da próxima faixa e na saída da atual."
                        ) {
                            DarkMenuPickerRow(
                                title: "Filtro Passa-Alta / Passa-Baixa",
                                selection: $p.automixFilterStyle,
                                valueLabel: p.automixFilterStyle.title,
                                options: AutomixFilterStyle.allCases.map { ($0, $0.title) }
                            )
                            DarkCardDivider()
                            DarkToggleRow(title: "Cauda de Reverb Espacial na Saída", isOn: $p.automixReverbEnabled)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
            .background(DarkSheetTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

/// Fundo da tela de reprodução: a capa borrada. O desfoque (caro na GPU) é calculado numa versão 8× menor da
/// imagem e depois ampliada, o que dá o mesmo visual com ~1/64 dos pixels; e, por ser uma view própria que só
/// depende da capa, não é recalculada quando a posição da faixa muda.
private struct AmbientCoverBackground: View {
    let coverArt: String?
    private static let shrink: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let coverArt {
                GeometryReader { geo in
                    CoverArtView(coverArt: coverArt, size: 300, cornerRadius: 0)
                        .frame(width: geo.size.width * 1.4 / Self.shrink, height: geo.size.height * 1.2 / Self.shrink)
                        .blur(radius: 75 / Self.shrink)
                        .scaleEffect(Self.shrink)
                        .opacity(0.42)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.35)
                }
                .ignoresSafeArea()
            }
            LinearGradient(
                colors: [Color.black.opacity(0.25), Color.black.opacity(0.65), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

/// Barra de progresso e tempos. É uma view própria de propósito: a posição da faixa muda várias vezes por segundo e,
/// lendo `player.currentTime` aqui dentro, só esta parte da tela é recalculada (antes era a tela de reprodução inteira).
private struct NowPlayingScrubberView: View {
    @Environment(AudioPlayerManager.self) private var player
    @State private var scrubValue: Double = 0
    @State private var isDragging = false
    let onOpenAutomixStudio: () -> Void

    var body: some View {
        let maxTime = max(player.effectiveScrubberEndTime, 1.0)
        let current = player.currentTime
        let activeTime = min(isDragging ? scrubValue : current, maxTime)
        VStack(spacing: 4) {
            DJScrubberSlider(
                value: $scrubValue,
                maxTime: maxTime,
                currentTime: current,
                isDragging: $isDragging,
                plan: player.shouldUseAutomix ? player.activeTransitionPlan : nil,
                onEditingChanged: { editing in
                    player.scrubbing(editing)
                    if !editing {
                        player.seek(to: min(scrubValue, maxTime))
                    }
                }
            )

            HStack(alignment: .center) {
                Text(formatTime(activeTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                Spacer()

                if player.currentSong != nil, player.shouldUseAutomix, let badge = player.automixBadge {
                    Button(action: onOpenAutomixStudio) {
                        AutomixPillBadgeView(badge: badge)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("-" + formatTime(max(maxTime - activeTime, 0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(height: 22)
        }
        .onAppear { scrubValue = player.currentTime }
        .onChange(of: player.currentTime) { _, t in if !isDragging { scrubValue = t } }
    }
}

/// Altura livre entre a base da capa e o título da música (medida no `Spacer` entre os dois).
private struct StageGapKey: PreferenceKey {
    static let defaultValue: CGFloat = 60
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
