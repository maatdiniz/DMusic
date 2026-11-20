import SwiftUI
import AVKit

struct NowPlayingView: View {
    @Environment(AudioPlayerManager.self) private var player
    @State private var scrubValue: Double = 0
    @State private var isDragging = false
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var showAutomixStudio = false
    @State private var dismissDragY: CGFloat = 0
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

                DJDualJogStageView(
                    stageMode: player.djStageMode,
                    currentCoverArt: player.currentSong?.coverArt,
                    deckACoverArt: player.djDeckACoverArt,
                    deckBCoverArt: player.djDeckBCoverArt,
                    deckARate: player.djDeckARate,
                    deckABPM: player.djDeckABPM,
                    deckBBPM: player.djDeckBBPM,
                    liveBPMTrend: player.liveBPMTrend,
                    isPlaying: player.isPlaying,
                    onSettlingFinished: { player.finishDJStageSettling() },
                    onSwipeNext: { player.next() },
                    onSwipePrevious: { player.previous() }
                )

                Spacer(minLength: 0)

                trackHeader

                scrubberSection

                transportControls

                bottomDock
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .artistPickerDialog(inNowPlaying: true)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showAddToPlaylist) {
            if let s = player.currentSong { AddToPlaylistSheet(songs: [s]) }
        }
        .sheet(isPresented: $showAutomixStudio) {
            AutomixStudioSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { scrubValue = player.currentTime }
        .onChange(of: player.currentTime) { _, t in if !isDragging { scrubValue = t } }
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
        ZStack {
            Color.black.ignoresSafeArea()
            if let cover = player.currentSong?.coverArt {
                GeometryReader { geo in
                    CoverArtView(coverArt: cover, size: 300, cornerRadius: 0)
                        .frame(width: geo.size.width * 1.4, height: geo.size.height * 1.2)
                        .blur(radius: 75)
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

            Menu {
                if let song = player.currentSong {
                    let entries = ArtistParser.artists(for: song)
                    if entries.count > 1 {
                        Menu {
                            ForEach(entries) { entry in
                                Button(entry.name) { player.navigateToArtistEntry(entry) }
                            }
                        } label: {
                            Label("Ir para o Artista", systemImage: "music.mic")
                        }
                    } else {
                        Button { player.navigateToSongArtist(song) } label: {
                            Label("Ir para o Artista", systemImage: "music.mic")
                        }
                    }
                    Button { player.navigateToSongAlbum(song) } label: {
                        Label("Ir para o Álbum", systemImage: "square.stack")
                    }
                }
                if let source = player.effectivePlaybackSource {
                    Button { player.navigateToSource() } label: {
                        Label("Ir para \(source.title)", systemImage: "arrow.turn.up.right")
                    }
                }
                if player.currentSong != nil {
                    Button { showAddToPlaylist = true } label: {
                        Label("Adicionar à playlist", systemImage: "music.note.list")
                    }
                }
                Button { showAutomixStudio = true } label: {
                    Label("Estúdio de Mixagem (EQ / Filtros)", systemImage: "slider.horizontal.3")
                }
                Menu {
                    ForEach([15, 30, 45, 60], id: \.self) { m in
                        Button("\(m) minutos") { player.setSleepTimer(minutes: m) }
                    }
                    Button("Ao fim da faixa") { player.sleepAfterCurrentTrack() }
                    if player.sleepEnd != nil || player.sleepAtEndOfTrack {
                        Button("Desativar", role: .destructive) { player.cancelSleep() }
                    }
                } label: {
                    Label("Dormir (\(sleepLabel))", systemImage: "moon.zzz.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
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

                        if analysisStore.metadata(for: song.id) != nil || player.liveAnimatedBPM != nil {
                            LiveBPMBadgeView(
                                staticMix: analysisStore.metadata(for: song.id),
                                liveBPM: player.liveAnimatedBPM,
                                trend: player.liveBPMTrend
                            )
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

    private var scrubberSection: some View {
        let maxTime = max(player.effectiveScrubberEndTime, 1.0)
        let activeTime = min(isDragging ? scrubValue : player.currentTime, maxTime)
        return VStack(spacing: 4) {
            DJScrubberSlider(
                value: $scrubValue,
                maxTime: maxTime,
                currentTime: player.currentTime,
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

                if let song = player.currentSong {
                    HStack(spacing: 5) {
                        if player.shouldUseAutomix, let badge = player.automixBadge {
                            Button { showAutomixStudio = true } label: {
                                AutomixPillBadgeView(badge: badge)
                            }
                            .buttonStyle(.plain)
                        } else if song.isHiRes {
                            QualityBadge(text: "HI-RES", highlighted: true)
                        }
                        if let q = song.qualityText {
                            QualityBadge(text: q)
                        }
                    }
                }

                Spacer()

                Text("-" + formatTime(max(maxTime - activeTime, 0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(height: 22)
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

            Spacer()

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

/// Palco 1:1 fixo e sem moldura com câmera virtual de mesa DJ:
/// - `.idle`: capa pura encaixada sem fundo/moldura (`fitInsideSquare: true`)
/// - `.ramping`: começa junto com a mudança de BPM; câmera afasta mostrando Deck A virando Jog e Deck B entrando pela direita já girando (Cue) no mesmo tamanho
/// - `.mixing`: Decks A e B giram lado a lado em tamanho idêntico e sincronia total (Deck A nunca encolhe)
/// - `.settling`: câmera dá zoom-in direto no Deck B empurrando Deck A girando pela lateral esquerda; Deck B freia no sentido horário até 0° cravado e desmascara virando capa.
private struct DJDualJogStageView: View {
    let stageMode: DJStageMode
    let currentCoverArt: String?
    let deckACoverArt: String?
    let deckBCoverArt: String?
    let deckARate: Float
    let deckABPM: Double?
    let deckBBPM: Double?
    let liveBPMTrend: Int
    let isPlaying: Bool
    let onSettlingFinished: () -> Void
    let onSwipeNext: () -> Void
    let onSwipePrevious: () -> Void

    private static let worldHalfGap: CGFloat = 0.62
    private static let worldXA: CGFloat = -worldHalfGap
    private static let worldXB: CGFloat = worldHalfGap
    private static let dualZoom: CGFloat = 0.44
    private static let wideCamDist: CGFloat = 1.0 / dualZoom
    private static let cruiseSpeed: Double = 200.0
    private static let brakeDuration: Double = 0.80
    private static let brakeDistance: Double = 80.0
    private static let unmaskDuration: Double = 0.44

    @State private var phaseStartDate = Date()
    @State private var anchorDate = Date()
    @State private var pausedAt: Date? = nil
    @State private var anchorAngleA: Double = 0.0
    @State private var anchorAngleB: Double = 0.0
    @State private var enteredFromRamping: Bool = false
    @State private var mixStartCameraT: Double = 0.0

    @State private var settleStartAngleA: Double = 0.0
    @State private var settleStartAngleB: Double = 0.0
    @State private var settleStartCamT: Double = 1.0
    @State private var settleRemB: Double = 360.0
    @State private var settleAlignDuration: Double = 1.6
    @State private var settleTask: Task<Void, Never>? = nil
    @State private var coverDragX: CGFloat = 0

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !(stageMode != .idle && isPlaying))) { timeline in
                        let evalDate = isPlaying ? timeline.date : (pausedAt ?? timeline.date)
                        stageContent(side: side, at: evalDate)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .onAppear {
                let now = Date()
                pausedAt = isPlaying ? nil : now
                anchorDate = now
                phaseStartDate = now
                anchorAngleA = 0
                anchorAngleB = 0
                if stageMode == .settling {
                    scheduleSettleFinish(remainingDelay: settleAlignDuration + Self.unmaskDuration + 0.04)
                }
            }
            .onChange(of: stageMode) { oldMode, newMode in
                let now = Date()
                let evalNow = isPlaying ? now : (pausedAt ?? now)
                settleTask?.cancel()
                settleTask = nil

                switch newMode {
                case .idle:
                    phaseStartDate = now
                    anchorDate = now
                    pausedAt = nil
                    anchorAngleA = 0
                    anchorAngleB = 0
                    enteredFromRamping = false
                    mixStartCameraT = 0.0

                case .ramping:
                    phaseStartDate = now
                    anchorDate = now
                    pausedAt = isPlaying ? nil : now
                    anchorAngleA = 0
                    anchorAngleB = 0
                    enteredFromRamping = false
                    mixStartCameraT = 0.0

                case .mixing:
                    if oldMode == .ramping {
                        let dt = max(0, evalNow.timeIntervalSince(phaseStartDate))
                        let speedA = Self.cruiseSpeed * Double(max(deckARate, 0.5))
                        anchorAngleA = anchorAngleA + Self.spinDelta(dt: dt, speed: speedA, rampUp: 0.45)
                        anchorAngleB = anchorAngleB + Self.cruiseSpeed * dt
                        mixStartCameraT = min(max(dt - 0.12, 0.0) / 0.74, 1.0)
                        enteredFromRamping = true
                    } else {
                        anchorAngleA = 0
                        anchorAngleB = 0
                        mixStartCameraT = 0.0
                        enteredFromRamping = false
                    }
                    phaseStartDate = now
                    anchorDate = now
                    pausedAt = isPlaying ? nil : now

                case .settling:
                    let dt = max(0, evalNow.timeIntervalSince(anchorDate))
                    let dtPhase = max(0, evalNow.timeIntervalSince(phaseStartDate))
                    let speedA = Self.cruiseSpeed * Double(max(deckARate, 0.5))

                    if oldMode == .mixing {
                        settleStartCamT = min(mixStartCameraT + dtPhase / 0.55, 1.0)
                        settleStartAngleA = anchorAngleA + (enteredFromRamping ? speedA * dt : Self.spinDelta(dt: dt, speed: speedA, rampUp: 0.25))
                        settleStartAngleB = anchorAngleB + Self.cruiseSpeed * dt
                    } else {
                        settleStartCamT = 1.0
                        settleStartAngleA = anchorAngleA
                        settleStartAngleB = anchorAngleB
                    }

                    var norm = settleStartAngleB.truncatingRemainder(dividingBy: 360.0)
                    if norm < 0 { norm += 360.0 }
                    let rawRem = norm < 0.01 ? 360.0 : (360.0 - norm)
                    let rem = rawRem < Self.brakeDistance ? (rawRem + 360.0) : rawRem
                    settleRemB = rem
                    settleAlignDuration = (rem - Self.brakeDistance) / Self.cruiseSpeed + Self.brakeDuration

                    phaseStartDate = now
                    anchorDate = now
                    pausedAt = isPlaying ? nil : now

                    if isPlaying {
                        scheduleSettleFinish(remainingDelay: settleAlignDuration + Self.unmaskDuration + 0.04)
                    }
                }
            }
            .onChange(of: isPlaying) { wasPlaying, nowPlaying in
                let now = Date()
                if wasPlaying && !nowPlaying {
                    pausedAt = now
                    if stageMode == .settling {
                        settleTask?.cancel()
                        settleTask = nil
                    }
                } else if !wasPlaying && nowPlaying {
                    if let pDate = pausedAt {
                        let pauseDelta = now.timeIntervalSince(pDate)
                        phaseStartDate = phaseStartDate.addingTimeInterval(pauseDelta)
                        anchorDate = anchorDate.addingTimeInterval(pauseDelta)
                        pausedAt = nil
                    }
                    if stageMode == .settling {
                        let elapsed = max(0, now.timeIntervalSince(phaseStartDate))
                        let total = settleAlignDuration + Self.unmaskDuration + 0.04
                        scheduleSettleFinish(remainingDelay: max(0.05, total - elapsed))
                    }
                }
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
    }

    private func scheduleSettleFinish(remainingDelay: Double) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remainingDelay))
            guard !Task.isCancelled else { return }
            onSettlingFinished()
        }
    }

    // MARK: - Funções Puras de Cinemática & Câmera Virtual

    private static func easeInOut(_ x: Double) -> Double {
        let t = min(max(x, 0.0), 1.0)
        return t < 0.5 ? (4.0 * t * t * t) : (1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0)
    }

    private static func spinDelta(dt: Double, speed: Double, rampUp: Double) -> Double {
        guard dt > 0 else { return 0 }
        let r = max(rampUp, 0.01)
        if dt <= r {
            return 0.5 * (speed / r) * dt * dt
        }
        return 0.5 * speed * r + speed * (dt - r)
    }

    private static func settlingAngleB(dt: Double, startAngle: Double, rem: Double, alignDuration: Double) -> Double {
        if dt <= 0 { return startAngle }
        if dt >= alignDuration { return startAngle + rem }
        if rem >= brakeDistance {
            let tCruise = (rem - brakeDistance) / cruiseSpeed
            if dt <= tCruise {
                return startAngle + cruiseSpeed * dt
            }
            let u = min(max((dt - tCruise) / brakeDuration, 0.0), 1.0)
            return startAngle + (rem - brakeDistance) + brakeDistance * (2.0 * u - u * u)
        } else {
            let u = min(max(dt / max(alignDuration, 0.01), 0.0), 1.0)
            return startAngle + rem * (2.0 * u - u * u)
        }
    }

    /// Mantém o prato 100% visível enquanto estiver dentro ou cruzando a borda da tela;
    /// só atenua quando já saiu completamente pela lateral da câmera.
    private static func edgeVisibility(offsetX: CGFloat, scale: CGFloat, side: CGFloat) -> Double {
        guard side > 1 else { return 1.0 }
        let halfDisk = 0.5 * scale * side
        let nearestEdge = max(0.0, abs(offsetX) - halfDisk) / side
        let fadeStart: CGFloat = 0.62
        let fadeEnd: CGFloat = 0.74
        if nearestEdge <= fadeStart { return 1.0 }
        if nearestEdge >= fadeEnd { return 0.0 }
        let t = (nearestEdge - fadeStart) / (fadeEnd - fadeStart)
        return Double(1.0 - easeInOut(Double(t)))
    }

    private static func syncRingColor(rate: Float) -> Color {
        if rate > 1.003 {
            return Color(red: 0.72, green: 0.36, blue: 1.0)   // Roxo/Violeta (aumentando BPM)
        } else if rate < 0.997 {
            return Color(red: 1.0, green: 0.34, blue: 0.38)   // Coral/Vermelho (reduzindo BPM)
        }
        return Color(red: 0.12, green: 0.88, blue: 0.42)      // Verde (reproduzindo normal)
    }

    // MARK: - Renderização por Fase

    @ViewBuilder
    private func stageContent(side: CGFloat, at evalDate: Date) -> some View {
        let dtPhase = max(0, evalDate.timeIntervalSince(phaseStartDate))
        let dtAnchor = max(0, evalDate.timeIntervalSince(anchorDate))
        let greenLED = Color(red: 0.12, green: 0.88, blue: 0.42)
        let amberLED = Color(red: 1.0, green: 0.62, blue: 0.12)
        let neutralLED = Color.white.opacity(0.68)

        switch stageMode {
        case .idle:
            MorphingCoverDiscView(
                coverArt: currentCoverArt,
                side: side,
                scale: isPlaying ? 1.0 : 0.92,
                circleMorph: 0.0,
                spinAngle: 0.0,
                jogChromeOpacity: 0.0,
                ringColor: neutralLED
            )
            .offset(x: coverDragX)
            .animation(.spring(duration: 0.38), value: isPlaying)
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { v in
                        if abs(v.translation.width) > abs(v.translation.height) {
                            coverDragX = v.translation.width * 0.75
                        }
                    }
                    .onEnded { v in
                        let dx = v.translation.width
                        if dx < -65 {
                            withAnimation(.easeOut(duration: 0.18)) { coverDragX = -side * 0.6 }
                            onSwipeNext()
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        } else if dx > 65 {
                            withAnimation(.easeOut(duration: 0.18)) { coverDragX = side * 0.6 }
                            onSwipePrevious()
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        } else {
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        }
                    }
            )

        case .ramping:
            let morphA = CGFloat(Self.easeInOut(min(dtPhase / 0.38, 1.0)))
            let camT = min(max(dtPhase - 0.12, 0.0) / 0.74, 1.0)
            let zoomEase = CGFloat(Self.easeInOut(camT))
            let camDist = 1.0 + (Self.wideCamDist - 1.0) * zoomEase
            let camZoom = 1.0 / camDist
            let camCenterX = Self.worldXA * (1.0 - zoomEase)

            let offsetXA = (Self.worldXA - camCenterX) * camZoom * side
            let offsetXB = (Self.worldXB - camCenterX) * camZoom * side

            let speedA = Self.cruiseSpeed * Double(max(deckARate, 0.5))
            let angleA = anchorAngleA + Self.spinDelta(dt: dtPhase, speed: speedA, rampUp: 0.45)
            // Segunda faixa já entra girando em pré-escuta (cue fantasma)
            let angleB = anchorAngleB + Self.cruiseSpeed * dtPhase

            let visB = Self.edgeVisibility(offsetX: offsetXB, scale: camZoom, side: side)
            let readoutAlpha = Self.easeInOut(min(max((camT - 0.35) / 0.65, 0.0), 1.0))
            let chipY = 0.5 * camZoom * side + 20.0
            let syncColor: Color = (liveBPMTrend == 0 && abs(deckARate - 1.0) >= 0.003)
                ? greenLED
                : Self.syncRingColor(rate: deckARate)

            ZStack {
                if visB > 0.01 {
                    MorphingCoverDiscView(
                        coverArt: deckBCoverArt,
                        side: side,
                        scale: camZoom,
                        circleMorph: 1.0,
                        spinAngle: angleB,
                        jogChromeOpacity: 1.0,
                        ringColor: amberLED
                    )
                    .offset(x: offsetXB)
                    .opacity(visB)
                }

                MorphingCoverDiscView(
                    coverArt: deckACoverArt ?? currentCoverArt,
                    side: side,
                    scale: camZoom,
                    circleMorph: morphA,
                    spinAngle: angleA,
                    jogChromeOpacity: Double(morphA),
                    ringColor: greenLED
                )
                .offset(x: offsetXA)

                if readoutAlpha > 0.01 {
                    let isChangingBPM = (liveBPMTrend != 0)
                    let blink = isChangingBPM ? (0.45 + 0.55 * (0.5 + 0.5 * sin(dtPhase * 7.0))) : 1.0
                    if let bpmA = deckABPM, bpmA > 0 {
                        DJDeckBPMChip(
                            bpm: bpmA,
                            trend: liveBPMTrend,
                            accent: isChangingBPM ? syncColor : greenLED,
                            blinkOpacity: blink
                        )
                        .offset(x: offsetXA, y: chipY)
                        .opacity(readoutAlpha)
                    }
                    if let bpmB = deckBBPM, bpmB > 0, visB > 0.05 {
                        DJDeckBPMChip(
                            bpm: bpmB,
                            trend: 0,
                            accent: amberLED,
                            blinkOpacity: 1.0
                        )
                        .offset(x: offsetXB, y: chipY)
                        .opacity(readoutAlpha * visB)
                    }
                }
            }

        case .mixing:
            let camT = min(mixStartCameraT + dtPhase / 0.55, 1.0)
            let zoomEase = CGFloat(Self.easeInOut(camT))
            let camDist = 1.0 + (Self.wideCamDist - 1.0) * zoomEase
            let camZoom = 1.0 / camDist
            let camCenterX = Self.worldXA * (1.0 - zoomEase)

            let offsetXA = (Self.worldXA - camCenterX) * camZoom * side
            let offsetXB = (Self.worldXB - camCenterX) * camZoom * side

            let morphA: CGFloat = enteredFromRamping ? 1.0 : CGFloat(Self.easeInOut(min(dtPhase / 0.32, 1.0)))
            let speedA = Self.cruiseSpeed * Double(max(deckARate, 0.5))
            let angleA = anchorAngleA + (enteredFromRamping ? speedA * dtAnchor : Self.spinDelta(dt: dtAnchor, speed: speedA, rampUp: 0.25))
            let angleB = anchorAngleB + Self.cruiseSpeed * dtAnchor

            let visB = Self.edgeVisibility(offsetX: offsetXB, scale: camZoom, side: side)
            let readoutAlpha = enteredFromRamping ? 1.0 : Self.easeInOut(min(max((camT - 0.35) / 0.65, 0.0), 1.0))
            let chipY = 0.5 * camZoom * side + 20.0

            ZStack {
                MorphingCoverDiscView(
                    coverArt: deckACoverArt,
                    side: side,
                    scale: camZoom,
                    circleMorph: morphA,
                    spinAngle: angleA,
                    jogChromeOpacity: Double(morphA),
                    ringColor: greenLED
                )
                .offset(x: offsetXA)

                if visB > 0.01 {
                    MorphingCoverDiscView(
                        coverArt: deckBCoverArt ?? currentCoverArt,
                        side: side,
                        scale: camZoom,
                        circleMorph: 1.0,
                        spinAngle: angleB,
                        jogChromeOpacity: 1.0,
                        ringColor: greenLED
                    )
                    .offset(x: offsetXB)
                    .opacity(visB)
                }

                if readoutAlpha > 0.01 {
                    if let bpmA = deckABPM, bpmA > 0 {
                        DJDeckBPMChip(
                            bpm: bpmA,
                            trend: 0,
                            accent: greenLED
                        )
                        .offset(x: offsetXA, y: chipY)
                        .opacity(readoutAlpha)
                    }
                    if let bpmB = deckBBPM, bpmB > 0, visB > 0.05 {
                        DJDeckBPMChip(
                            bpm: bpmB,
                            trend: 0,
                            accent: greenLED
                        )
                        .offset(x: offsetXB, y: chipY)
                        .opacity(readoutAlpha * visB)
                    }
                }
            }

        case .settling:
            let alignU = CGFloat(Self.easeInOut(min(dtPhase / max(settleAlignDuration, 0.01), 1.0)))
            let startEase = CGFloat(Self.easeInOut(settleStartCamT))
            let startDist = 1.0 + (Self.wideCamDist - 1.0) * startEase
            let startCamX = Self.worldXA * (1.0 - startEase)

            // A câmera foca e faz zoom-in no Deck B, empurrando naturalmente o Deck A pela lateral esquerda
            let camDist = startDist + (1.0 - startDist) * alignU
            let camZoom = 1.0 / camDist
            let camCenterX = startCamX + (Self.worldXB - startCamX) * alignU

            let speedA = Self.cruiseSpeed * Double(max(deckARate, 0.5))
            let angleA = settleStartAngleA + speedA * dtPhase
            let offsetXA = (Self.worldXA - camCenterX) * camZoom * side
            let visA = dtPhase >= settleAlignDuration ? 0.0 : Self.edgeVisibility(offsetX: offsetXA, scale: camZoom, side: side)

            // Sub-fase 4A (0 .. settleAlignDuration): câmera zoom-in até Deck B 100% centrado, freia até 0° cravado
            // Sub-fase 4B (settleAlignDuration .. settleAlignDuration + unmaskDuration): já parada a 0° no centro, vira capa!
            let angleB = Self.settlingAngleB(
                dt: dtPhase,
                startAngle: settleStartAngleB,
                rem: settleRemB,
                alignDuration: settleAlignDuration
            )
            let offsetXB = (Self.worldXB - camCenterX) * camZoom * side

            let chromeFadeStart: CGFloat = 0.55
            let chromeFadeEnd: CGFloat = 0.96
            let chromeT = min(max((alignU - chromeFadeStart) / (chromeFadeEnd - chromeFadeStart), 0.0), 1.0)
            let chromeOpacityB = dtPhase >= settleAlignDuration ? 0.0 : Double(1.0 - chromeT)

            let unmaskProgress: CGFloat = dtPhase <= settleAlignDuration
                ? 0.0
                : CGFloat(Self.easeInOut(min((dtPhase - settleAlignDuration) / Self.unmaskDuration, 1.0)))
            let morphB: CGFloat = 1.0 - unmaskProgress

            let chipFade = max(0.0, 1.0 - Self.easeInOut(min(dtPhase / 0.32, 1.0)))
            let chipY = 0.5 * camZoom * side + 20.0

            ZStack {
                if visA > 0.01, let outCover = deckACoverArt {
                    MorphingCoverDiscView(
                        coverArt: outCover,
                        side: side,
                        scale: camZoom,
                        circleMorph: 1.0,
                        spinAngle: angleA,
                        jogChromeOpacity: 1.0,
                        ringColor: neutralLED
                    )
                    .offset(x: offsetXA)
                    .opacity(visA)
                }

                MorphingCoverDiscView(
                    coverArt: deckBCoverArt ?? currentCoverArt,
                    side: side,
                    scale: camZoom,
                    circleMorph: morphB,
                    spinAngle: angleB,
                    jogChromeOpacity: chromeOpacityB,
                    ringColor: greenLED
                )
                .offset(x: offsetXB)

                if chipFade > 0.01 {
                    if let bpmA = deckABPM, bpmA > 0, visA > 0.01 {
                        DJDeckBPMChip(
                            bpm: bpmA,
                            trend: 0,
                            accent: neutralLED
                        )
                        .offset(x: offsetXA, y: chipY)
                        .opacity(chipFade * visA)
                    }
                    if let bpmB = deckBBPM, bpmB > 0 {
                        DJDeckBPMChip(
                            bpm: bpmB,
                            trend: 0,
                            accent: greenLED
                        )
                        .offset(x: offsetXB, y: chipY)
                        .opacity(chipFade)
                    }
                }
            }
        }
    }
}

/// Pílula compacta com BPM animado em tempo real exibida sob os pratos durante a transição (sem rótulos de Deck/Cue).
private struct DJDeckBPMChip: View {
    let bpm: Double
    let trend: Int
    let accent: Color
    var blinkOpacity: Double = 1.0

    var body: some View {
        let formatted = String(format: "%.1f", bpm)
        let activeBorder = trend != 0
            ? accent.opacity(0.35 + 0.55 * blinkOpacity)
            : accent.opacity(0.65)
        let activeBg = trend != 0
            ? Color(white: 0.22).opacity(0.55 * (1.0 - blinkOpacity))
            : Color.clear

        HStack(spacing: 4) {
            if trend != 0 {
                Image(systemName: trend > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(accent.opacity(0.45 + 0.55 * blinkOpacity))
            }

            Text("\(formatted) BPM")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: trend < 0))
                .animation(.easeOut(duration: 0.12), value: formatted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.black.opacity(0.56), in: Capsule(style: .continuous))
        .background(activeBg, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(activeBorder, lineWidth: 1.0)
        )
    }
}

/// Badge da barra de controle que exibe o BPM discreto e a tonalidade padronizada na paleta suavizada de Camelot (sem bordas).
private struct LiveBPMBadgeView: View {
    let staticMix: TrackMixMetadata?
    let liveBPM: Double?
    let trend: Int

    private let discreteText = Color.white.opacity(0.72)
    private let discreteBg = Color.white.opacity(0.10)

    var body: some View {
        HStack(spacing: 4) {
            if let liveBPM {
                let formatted = String(format: "%.1f", liveBPM)
                HStack(spacing: 3) {
                    if trend != 0 {
                        Image(systemName: trend > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    Text(formatted)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: trend < 0))
                        .animation(.easeOut(duration: 0.12), value: formatted)
                    Text("BPM")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(discreteBg, in: Capsule())
                .foregroundStyle(discreteText)
            } else if let mix = staticMix {
                QualityBadge(text: "\(mix.formattedBPM) BPM")
            }

            if let camelot = staticMix?.camelot, !camelot.isEmpty {
                CamelotBadge(camelot: camelot)
            }
        }
    }
}

/// Arte da capa sem moldura que interpola perfeitamente de:
/// - `circleMorph == 0.0`: capa completa sem recorte (`fitW × fitH`, `cornerRadius: 16 * scale`)
/// - `circleMorph == 1.0`: disco circular perfeito preenchendo `targetSide × targetSide`,
/// mantendo os anéis de Jog Wheel nítidos na escala final sem double-scaling.
private struct MorphingCoverDiscView: View {
    let coverArt: String?
    let side: CGFloat
    let scale: CGFloat
    let circleMorph: CGFloat
    let spinAngle: Double
    let jogChromeOpacity: Double
    let ringColor: Color

    @Environment(AuthViewModel.self) private var auth
    @State private var loadedImage: UIImage?

    private func fittedDimensions(for image: UIImage?, targetSide: CGFloat) -> (CGFloat, CGFloat) {
        guard let img = image, img.size.width > 0, img.size.height > 0 else {
            return (targetSide, targetSide)
        }
        let aspect = img.size.width / img.size.height
        return aspect >= 1.0
            ? (targetSide, targetSide / aspect)
            : (targetSide * aspect, targetSide)
    }

    var body: some View {
        let targetSide = max(side * scale, 1)
        let m = min(max(circleMorph, 0.0), 1.0)
        let resolvedImage = loadedImage ?? coverArt.flatMap { ImageCache.shared.cachedImage(id: $0, size: 600) }
        let (fitW, fitH) = fittedDimensions(for: resolvedImage, targetSide: targetSide)

        let boxW = fitW + (targetSide - fitW) * m
        let boxH = fitH + (targetSide - fitH) * m
        let baseCorner = 16.0 * scale
        let cr = baseCorner + (min(boxW, boxH) * 0.5 - baseCorner) * m

        ZStack {
            Group {
                if let resolvedImage {
                    Image(uiImage: resolvedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: max(18, 28 * scale), weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    )
                }
            }
            .frame(width: boxW, height: boxH)
            .clipShape(RoundedRectangle(cornerRadius: cr, style: .continuous))
            .rotationEffect(.degrees(spinAngle))

            if jogChromeOpacity > 0.005 {
                // Anel LED externo + ponto marcador às 12h girando com o prato para deixar claro o pouso em 0°
                ZStack {
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    ringColor.opacity(0.95),
                                    Color.white.opacity(0.25),
                                    ringColor.opacity(0.55),
                                    Color.white.opacity(0.25),
                                    ringColor.opacity(0.95)
                                ],
                                center: .center
                            ),
                            lineWidth: 3.0
                        )
                        .shadow(color: ringColor.opacity(0.50), radius: 8)

                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .offset(y: -(targetSide * 0.5 - 6.0))
                }
                .frame(width: targetSide, height: targetSide)
                .rotationEffect(.degrees(spinAngle))
                .opacity(jogChromeOpacity)

                // Sulco sutil interno de vinil/CDJ
                Circle()
                    .strokeBorder(Color.black.opacity(0.38), lineWidth: max(4.0, targetSide * 0.032))
                    .frame(width: targetSide * 0.94, height: targetSide * 0.94)
                    .opacity(jogChromeOpacity)

                // Spindle central compacto do prato CDJ
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.84))
                    Circle()
                        .strokeBorder(ringColor.opacity(0.85), lineWidth: 1.6)
                    Circle()
                        .fill(Color(white: 0.80))
                        .frame(width: targetSide * 0.048, height: targetSide * 0.048)
                }
                .frame(width: targetSide * 0.18, height: targetSide * 0.18)
                .opacity(jogChromeOpacity)
            }
        }
        .frame(width: targetSide, height: targetSide)
        .shadow(color: .black.opacity(0.55), radius: 22 * scale, y: 10 * scale)
        .task(id: coverArt) {
            guard let coverArt else {
                loadedImage = nil
                return
            }
            if let hit = ImageCache.shared.cachedImage(id: coverArt, size: 600) {
                loadedImage = hit
            } else {
                loadedImage = nil
                loadedImage = await ImageCache.shared.image(id: coverArt, size: 600, client: auth.client)
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
                // Trilho base
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: w, height: trackH)

                // Trecho de mudança de BPM + trecho em cinza claro onde mantém o novo BPM
                if let zone {
                    let zoneX = w * zone.startFrac
                    if let holdFrac = zone.holdStartFrac {
                        let holdX = w * holdFrac
                        let rampW = max(0, holdX - zoneX)
                        let holdW = max(0, w - holdX)

                        Rectangle()
                            .fill(zone.color.opacity(0.65))
                            .frame(width: rampW, height: trackH)
                            .offset(x: zoneX)

                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.42))
                            .frame(width: holdW, height: trackH)
                            .offset(x: holdX)
                    } else {
                        let zoneW = max(0, w - zoneX)
                        Capsule(style: .continuous)
                            .fill(zone.color.opacity(0.65))
                            .frame(width: zoneW, height: trackH)
                            .offset(x: zoneX)
                    }
                }

                // Progresso percorrido sempre em branco (sem pintar a barra toda da cor do final)
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: max(trackH, fillW), height: trackH)

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
/// - `armed`: azul discreto (SINC MM:SS ↑/↓)
/// - `syncUp`: âmbar/laranja vibrante (SINC ↑ aumentando BPM)
/// - `syncDown`: ciano/azul elétrico (SINC ↓ reduzindo BPM)
/// - `syncSteady`: verde esmeralda (SINC = BPM cravado)
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
