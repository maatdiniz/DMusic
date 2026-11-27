import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import Observation
import Combine

enum RepeatMode { case off, all, one }

nonisolated struct SavedPlayback: Codable, Sendable {
    let songs: [Song]
    let index: Int
    let time: Double
    var source: PlaybackSource?
    var originalSongs: [Song]?
    var shuffle: Bool?
}

@Observable
@MainActor
final class AudioPlayerManager {
    var queue: [Song] = []
    var originalQueue: [Song] = []
    var currentIndex: Int = 0
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var showNowPlaying = false {
        // Com o player fechado ninguém vê a barra andar: atualiza a posição com bem menos frequência
        didSet { automixEngine.uiUpdateInterval = showNowPlaying ? 0.1 : 0.5 }
    }
    @ObservationIgnored private var lastNowPlayingSync: CFAbsoluteTime = 0
    @ObservationIgnored private var lastStateSave: CFAbsoluteTime = 0
    var playbackSource: PlaybackSource?
    var selectedTab: AppTab = .home
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var requestedLibrarySection: LibrarySection?
    var requestedSearchQuery: String?
    var searchFocusTrigger: Int = 0
    var visibleDetailId: String?

    /// Toca junto com o áudio de outros apps (vídeo, podcast, outro player) em vez de pausar ou ser pausado.
    /// Usa a opção `.mixWithOthers` da sessão de áudio; quem decide o volume de cada um é o usuário.
    var mixWithOtherApps: Bool {
        didSet {
            UserDefaults.standard.set(mixWithOtherApps, forKey: "mix_with_other_apps")
            configureSession()
        }
    }

    /// Automix automático (sincroniza BPM com rampa na Faixa A antes da entrada,
    /// dispara Faixa B no downbeat via AVAudioEngine + Bass Swap e usa SmartShuffler).
    var automixEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixEnabled, forKey: "automix_enabled")
            if automixEnabled {
                logEvent("ENGINE", "Automix ativado", detail: "Fila mantida intacta. Modo Dual-Deck 48 kHz + EQ 5 bandas + Filtros ativo.")
                Task { await analysisStore?.syncFromServerIfStale(mixClient: mixClient) }
                onAutomixEnabledMidTrack()
            } else {
                logEvent("ENGINE", "Automix desativado", detail: "Fila mantida intacta. Retornando para reprodução Gapless pura.")
                automixPrepareTask?.cancel()
                automixEngine.clearPreparedIncoming()
                isAutomixing = false
                preparedMixHint = nil
                automixBadge = nil
                activeTransitionPlan = nil
                resetCoverStage()
            }
            preloadNextInGapless()
        }
    }
    private(set) var isAutomixing = false
    var preparedMixHint: String?
    /// Badge curto, discreto e colorido exibido na tela de reprodução (ex.: "SYNC ↑", "SYNC ↓", "MIX • 3B", "MIX • EQ").
    var automixBadge: AutomixIndicatorBadge?
    /// Plano de transição armado para a faixa atual (usado para limitar o slider antes da transição e colorir a zona de rampa de BPM).
    var activeTransitionPlan: TransitionPlan?
    /// Estado visual das capas A & B na transição DJ (idle -> ramping -> mixing -> settling -> idle).
    var coverStageMode: CoverStageMode = .idle
    var stageCoverArtA: String? = nil
    var stageCoverArtB: String? = nil
    var stageRateA: Float = 1.0
    /// BPM efetivo em tempo real durante rampa de sincronização, mixagem ou recuperação pós-transição (`nil` = exibir estático).
    var liveAnimatedBPM: Double? = nil
    /// Tendência do BPM ao vivo: `+1` subindo (roxo), `-1` descendo (coral), `0` cravado/sincronizado (verde).
    var liveBPMTrend: Int = 0
    /// BPM exibido sob a Capa A e sob a Capa B no palco.
    var stageBPMA: Double? = nil
    var stageBPMB: Double? = nil
    @ObservationIgnored private var stageSettleSafetyTask: Task<Void, Never>?

    // MARK: Menus de ação (painel único na raiz do app)

    /// Menu de ações aberto no momento (faixa, álbum, opções do player…); `nil` = fechado.
    var actionMenu: ActionMenuRequest?
    /// Seletor de playlist, aberto depois que o menu fecha.
    var playlistPicker: PlaylistPickerRequest?

    /// Seletor de gêneros (música ou álbum), aberto depois que o menu fecha.
    var genrePicker: GenrePickerRequest?

    func presentGenrePicker(title: String, songs: [Song], albumId: String? = nil) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            self?.genrePicker = GenrePickerRequest(title: title, songs: songs, albumId: albumId)
        }
    }

    /// Abre o seletor de playlist com uma pequena espera, para não colidir com o painel de menu que está fechando.
    func presentPlaylistPicker(for songs: [Song]) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            self?.playlistPicker = PlaylistPickerRequest(songs: songs)
        }
    }

    // MARK: Indicador de carregamento (quadrado de reticências)

    /// Texto do indicador global de carregamento; `nil` quando nada pesado está em andamento.
    var busyMessage: String?
    @ObservationIgnored private var busyEntries: [(id: UUID, message: String)] = []
    @ObservationIgnored private var queueBuildTask: Task<Void, Never>?
    @ObservationIgnored private var reorderTask: Task<Void, Never>?

    /// Mostra o indicador até `endBusy` ser chamado com o token devolvido (vários trabalhos podem se sobrepor).
    @discardableResult
    func beginBusy(_ message: String) -> UUID {
        let id = UUID()
        busyEntries.append((id, message))
        busyMessage = message
        return id
    }

    func endBusy(_ token: UUID) {
        busyEntries.removeAll { $0.id == token }
        busyMessage = busyEntries.last?.message
    }

    /// Executa `work` mostrando o indicador de carregamento enquanto durar.
    func withBusy<T>(_ message: String, _ work: () async -> T) async -> T {
        let token = beginBusy(message)
        defer { endBusy(token) }
        return await work()
    }

    /// Smart Shuffle + relatório calculados fora da thread principal.
    nonisolated private static func smartOrder(
        songs: [Song],
        metadata: [String: TrackMixMetadata],
        anchor: Song?,
        focus: SmartShuffler.GenreFocus = .none
    ) -> (queue: [Song], report: SmartShuffleRunLog) {
        let ordered = SmartShuffler.smartShuffle(songs: songs, metadata: metadata, startingWith: anchor, genreFocus: focus)
        return (ordered, SmartShuffler.buildShuffleReport(orderedSongs: ordered, metadata: metadata))
    }

    private func publishSmartShuffleLog(_ report: SmartShuffleRunLog, reason: String) {
        lastSmartShuffleLog = report
        logEvent(
            "SHUFFLE",
            "\(reason) (\(report.totalTracks) faixas • média \(Int(report.averageScore.rounded())) pts)",
            detail: "IA allin1: \(report.aiAnalyzedCount) • Local: \(report.localAnalyzedCount) • Sem análise: \(report.unanalyzedCount)"
        )
    }

    private func resetCoverStage(clearLiveBPM: Bool = true) {
        stageSettleSafetyTask?.cancel()
        stageSettleSafetyTask = nil
        coverStageMode = .idle
        stageCoverArtA = nil
        stageCoverArtB = nil
        stageRateA = 1.0
        stageBPMA = nil
        stageBPMB = nil
        if clearLiveBPM {
            liveAnimatedBPM = nil
            liveBPMTrend = 0
        }
    }

    func finishCoverStageSettling() {
        guard coverStageMode == .settling else { return }
        resetCoverStage(clearLiveBPM: false)
    }

    /// Snapshot instantâneo O(1) dos dois decks para o Espectrograma Rekordbox a 60 FPS.
    func liveDeckSnapshot() -> AutomixAudioEngine.LiveDeckSnapshot {
        if usingEngineMode {
            return automixEngine.liveDeckSnapshot()
        }
        let curId = currentSong?.id
        let bpmA = curId.flatMap { analysisStore?.metadata(for: $0)?.effectiveBPM } ?? 0
        return AutomixAudioEngine.LiveDeckSnapshot(
            songIdA: curId,
            timeA: currentTime,
            durationA: duration,
            rateA: 1.0,
            nominalBPMA: bpmA,
            songIdB: nil,
            timeB: 0,
            durationB: 0,
            rateB: 1.0,
            nominalBPMB: 0,
            hasStartedIncoming: false,
            phase: .playing,
            plan: nil
        )
    }

    /// Fim visível da barra de progresso: no modo DJ (`shouldUseAutomix`) com transição armada, vai exatamente até o início da transição (`mixStartSec`).
    var effectiveScrubberEndTime: Double {
        let baseDur = max(duration, 1.0)
        guard shouldUseAutomix, let plan = activeTransitionPlan else { return baseDur }
        let mixStart = plan.trackA.mixStartSec
        if mixStart > 4.0 && mixStart < baseDur {
            return mixStart
        }
        return baseDur
    }

    // MARK: Logs do Sistema Automix & Ordem do Smart Shuffle
    var lastSmartShuffleLog: SmartShuffleRunLog?

    nonisolated private func logEvent(_ category: String, _ title: String, detail: String) {
        print("[\(category)] \(title) — \(detail)")
    }

    func clearLogs() {
        lastSmartShuffleLog = nil
        AppLogger.shared.clearLog()
    }

    // MARK: Preferências do DJ Automix (Duração, Curva de Volume, EQ, Filtros e Reverb)
    var automixDurationChoice: AutomixDurationChoice {
        didSet {
            UserDefaults.standard.set(automixDurationChoice.rawValue, forKey: "automix_duration_choice")
            reprepareIncomingIfNeeded()
        }
    }
    var automixVolumeCurve: AutomixVolumeCurve {
        didSet {
            UserDefaults.standard.set(automixVolumeCurve.rawValue, forKey: "automix_volume_curve")
            reprepareIncomingIfNeeded()
        }
    }
    var automixEQStyle: AutomixEQStyle {
        didSet {
            UserDefaults.standard.set(automixEQStyle.rawValue, forKey: "automix_eq_style")
            reprepareIncomingIfNeeded()
        }
    }
    var automixFilterStyle: AutomixFilterStyle {
        didSet {
            UserDefaults.standard.set(automixFilterStyle.rawValue, forKey: "automix_filter_style")
            reprepareIncomingIfNeeded()
        }
    }
    var automixReverbEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixReverbEnabled, forKey: "automix_reverb_enabled")
            reprepareIncomingIfNeeded()
        }
    }

    var client: SubsonicClient?
    var mixClient: MixServerClient?
    @ObservationIgnored var downloads: DownloadManager?
    @ObservationIgnored var recents: RecentSongsCache?
    @ObservationIgnored var scrobbler: ScrobbleManager?
    @ObservationIgnored var settings: CacheSettings?
    @ObservationIgnored var analysisStore: TrackAnalysisStore?
    @ObservationIgnored var transitionAudit: TransitionAuditStore?
    @ObservationIgnored private var preparedPairContext: (from: Song, to: Song, appliedOverride: Bool)?
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Sleep timer: horário em que a música vai pausar (nil = desligado).
    var sleepEnd: Date?
    /// Pausa ao fim da faixa atual.
    var sleepAtEndOfTrack = false
    // Controle da regra de scrobble (tempo realmente ouvido da faixa atual)
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastTick: Double = 0
    @ObservationIgnored private var songStart = Date()
    @ObservationIgnored private var didScrobble = false

    var currentSong: Song? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

    var nextSongInQueue: Song? {
        guard let idx = nextAutoIndex(), queue.indices.contains(idx) else { return nil }
        return queue[idx]
    }

    var effectivePlaybackSource: PlaybackSource? {
        if let playbackSource { return playbackSource }
        if let s = currentSong, let albumId = s.albumId {
            return .album(Album(id: albumId, name: s.album, title: s.album, artist: s.artist, artistId: s.artistId, coverArt: s.coverArt, year: s.year))
        }
        return nil
    }

    // Modo Gapless puro: AVQueuePlayer único
    @ObservationIgnored private let gaplessPlayer = AVQueuePlayer()
    // Modo Automix: AVAudioEngine Dual-Deck com AVAudioUnitTimePitch + AVAudioUnitEQ (Bass Swap)
    @ObservationIgnored private let automixEngine = AutomixAudioEngine()
    @ObservationIgnored private var usingEngineMode = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var itemObserver: AnyCancellable?
    @ObservationIgnored private var commandsConfigured = false
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var activeItem: AVPlayerItem?
    @ObservationIgnored private var itemIndex: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var preloadedIndex: Int?
    @ObservationIgnored private var automixPrepareTask: Task<Void, Never>?
    @ObservationIgnored private var isAudioSessionActive = false
    /// Quantas faixas logo após a atual foram colocadas por "Tocar a seguir" (têm prioridade mesmo no shuffle).
    private(set) var priorityCount = 0

    init() {
        mixWithOtherApps = UserDefaults.standard.object(forKey: "mix_with_other_apps") as? Bool ?? false
        automixEnabled = UserDefaults.standard.object(forKey: "automix_enabled") as? Bool ?? false
        let rawDur = UserDefaults.standard.integer(forKey: "automix_duration_choice")
        automixDurationChoice = AutomixDurationChoice(rawValue: rawDur) ?? .auto
        let rawVol = UserDefaults.standard.string(forKey: "automix_volume_curve") ?? AutomixVolumeCurve.auto.rawValue
        automixVolumeCurve = AutomixVolumeCurve(rawValue: rawVol) ?? .auto
        let rawEQ = UserDefaults.standard.string(forKey: "automix_eq_style") ?? AutomixEQStyle.auto.rawValue
        automixEQStyle = AutomixEQStyle(rawValue: rawEQ) ?? .auto
        let rawFilter = UserDefaults.standard.string(forKey: "automix_filter_style") ?? AutomixFilterStyle.auto.rawValue
        automixFilterStyle = AutomixFilterStyle(rawValue: rawFilter) ?? .auto
        automixReverbEnabled = UserDefaults.standard.object(forKey: "automix_reverb_enabled") as? Bool ?? false
        configureSession()
        configureRemoteCommands()
        observeAudioSession()
        setupGaplessPlayer()
        setupAutomixEngineCallbacks()
    }

    /// Tarefas periódicas baratas e espaçadas por tempo (não por tick): o Centro de Controle extrapola a posição sozinho
    /// (taxa de reprodução + tempo decorrido), então só precisa ser ressincronizado de vez em quando; o estado da fila
    /// é gravado a cada 15 s.
    private func periodicHousekeeping() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastNowPlayingSync >= 15 {
            lastNowPlayingSync = now
            updateNowPlayingProgress()
        }
        if now - lastStateSave >= 15 {
            lastStateSave = now
            saveState()
        }
    }

    private func setupGaplessPlayer() {
        gaplessPlayer.actionAtItemEnd = .advance
        gaplessPlayer.automaticallyWaitsToMinimizeStalling = true
        gaplessPlayer.allowsExternalPlayback = false

        timeObserver = gaplessPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.usingEngineMode, !self.isScrubbing else { return }
                let sec = t.seconds.isFinite ? t.seconds : 0
                self.currentTime = sec
                self.trackListening(sec)
                self.periodicHousekeeping()
                if let d = self.gaplessPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
            }
        }

        itemObserver = gaplessPlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                MainActor.assumeIsolated {
                    guard let self, !self.usingEngineMode else { return }
                    self.currentItemChanged(item)
                }
            }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.usingEngineMode,
                      let item = note.object as? AVPlayerItem, item === self.activeItem,
                      self.preloadedIndex == nil else { return }
                if !self.sleepAtEndOfTrack, let nextIdx = self.nextAutoIndex() {
                    self.load(index: nextIdx, autoplay: true)
                } else {
                    self.queueFinished()
                }
            }
        }
    }

    private func setupAutomixEngineCallbacks() {
        automixEngine.onTimeUpdate = { [weak self] t, dur in
            guard let self, self.usingEngineMode, !self.isScrubbing else { return }
            self.currentTime = t
            if dur > 0 { self.duration = dur }
            self.trackListening(t)
            self.periodicHousekeeping()
        }

        automixEngine.onPhaseChanged = { [weak self] phase, plan in
            guard let self else { return }
            switch phase {
            case .idle, .playing:
                self.isAutomixing = false
                if self.coverStageMode == .ramping {
                    self.resetCoverStage()
                }
            case .ramping:
                self.isAutomixing = true
                let rateA = plan?.sync.targetRateA ?? 1.0
                if rateA > 1.003 {
                    self.automixBadge = AutomixIndicatorBadge(text: "SYNC", icon: "arrowtriangle.up.fill", kind: .syncUp)
                } else if rateA < 0.997 {
                    self.automixBadge = AutomixIndicatorBadge(text: "SYNC", icon: "arrowtriangle.down.fill", kind: .syncDown)
                } else {
                    self.automixBadge = AutomixIndicatorBadge(text: "SYNC", icon: "equal", kind: .syncSteady)
                }
                self.stageSettleSafetyTask?.cancel()
                let nextSongForStage = plan.flatMap { p in self.queue.first(where: { $0.id == p.trackB.id }) } ?? self.nextSongInQueue
                self.stageCoverArtA = self.currentSong?.coverArt
                self.stageCoverArtB = nextSongForStage?.coverArt
                self.stageRateA = rateA
                if let p = plan {
                    self.stageBPMA = p.trackA.bpm > 0 ? p.trackA.bpm : nil
                    let effectiveB = p.trackB.bpm * Double(p.sync.initialRateB ?? 1.0)
                    self.stageBPMB = effectiveB > 0 ? effectiveB : nil
                    if p.transitionType == "beatmatch", abs(rateA - 1.0) >= 0.003, p.trackA.bpm > 0 {
                        self.liveAnimatedBPM = p.trackA.bpm
                        self.liveBPMTrend = rateA > 1.0 ? 1 : -1
                    }
                }
                self.coverStageMode = .ramping

                if let p = plan {
                    let pct = String(format: "%+.1f%%", (p.sync.targetRateA - 1.0) * 100.0)
                    self.logEvent("SYNC", "Sincronizando BPM (\(pct))", detail: "Rampa iniciada em \(Self.formatMMSS(p.trackA.rampStartSec)) rumo a \(Self.formatMMSS(p.trackA.mixStartSec))")
                }
            case .mixing:
                let badge = Self.activeMixingBadge(for: plan)
                self.isAutomixing = true
                self.automixBadge = badge
                // Deck B já assumiu a barra de progresso — limpa o plano da Faixa A para não desenhar
                // a zona colorida de rampa da faixa anterior sobre a barra da nova faixa.
                self.activeTransitionPlan = nil
                if let p = plan {
                    let vol = AutomixVolumeCurve(rawValue: p.mix.volumeCurve ?? "")?.title ?? "Sobrepor"
                    let eq = AutomixEQStyle(rawValue: p.mix.eqStyle ?? "")?.title ?? "Troca de Grave central"
                    let flt = AutomixFilterStyle(rawValue: p.mix.filterStyle ?? "")?.title ?? "Passa-alta"
                    self.logEvent(
                        "MIX",
                        "Mixando (\(p.mix.bars ?? 8) compassos • \(badge.text))",
                        detail: "Saída \(Self.formatMMSS(p.trackA.mixStartSec)) (\(p.trackA.section ?? "inst")) → Entrada \(Self.formatMMSS(p.trackB.entrySec)) (\(p.trackB.section ?? "drop")) | Vol: \(vol) | EQ: \(eq) | Filtro: \(flt)"
                    )
                    if let ctx = self.preparedPairContext,
                       ctx.from.id == p.trackA.id,
                       ctx.to.id == p.trackB.id {
                        self.transitionAudit?.recordTransition(
                            from: ctx.from,
                            to: ctx.to,
                            plan: p,
                            appliedOverride: ctx.appliedOverride
                        )
                        self.preparedPairContext = nil
                    }
                }
            }
        }

        automixEngine.onLiveBPMChanged = { [weak self] bpm, trend in
            guard let self else { return }
            self.liveAnimatedBPM = bpm
            self.liveBPMTrend = trend
            if self.coverStageMode == .ramping, let bpm {
                self.stageBPMA = bpm
                if trend == 0, let p = self.activeTransitionPlan,
                   p.transitionType == "beatmatch", abs(p.sync.targetRateA - 1.0) >= 0.003 {
                    self.automixBadge = AutomixIndicatorBadge(text: "SYNC", icon: "equal", kind: .syncSteady)
                }
            } else if self.coverStageMode == .mixing, let bpm {
                self.stageBPMA = bpm
                self.stageBPMB = bpm
            }
        }

        automixEngine.onTransitionStarted = { [weak self] newSongId in
            guard let self else { return }
            let previousSong = self.currentSong
            let expectedIdx = self.nextAutoIndex()
            let resolvedIdx: Int?
            if let exp = expectedIdx, self.queue.indices.contains(exp), self.queue[exp].id == newSongId {
                resolvedIdx = exp
            } else {
                resolvedIdx = self.queue.firstIndex(where: { $0.id == newSongId })
            }
            guard let idx = resolvedIdx else { return }

            self.stageSettleSafetyTask?.cancel()
            if let prev = previousSong,
               (self.preparedPairContext?.from.id != prev.id || self.preparedPairContext?.to.id != self.queue[idx].id) {
                let hadOverride = self.transitionAudit?.override(from: prev.id, to: self.queue[idx].id)?.hasParameterCustomizations ?? false
                self.preparedPairContext = (from: prev, to: self.queue[idx], appliedOverride: hadOverride)
            }
            if self.coverStageMode != .ramping {
                self.stageCoverArtA = previousSong?.coverArt
                self.stageCoverArtB = self.queue[idx].coverArt
                self.stageRateA = self.activeTransitionPlan?.sync.targetRateA ?? 1.0
                if let p = self.activeTransitionPlan {
                    let rateA = p.sync.targetRateA
                    let effectiveA = p.trackA.bpm * Double(rateA)
                    let effectiveB = p.trackB.bpm * Double(p.sync.initialRateB ?? 1.0)
                    self.stageBPMA = effectiveA > 0 ? effectiveA : nil
                    self.stageBPMB = effectiveB > 0 ? effectiveB : nil
                }
            }
            self.coverStageMode = .mixing

            // Assim que o slider chega ao fim (mixStartSec) e a Música B começa a entrar,
            // a tela já exibe imediatamente a capa, título, artista e tempo da Música B!
            self.consumePriority(movingTo: idx)
            self.currentIndex = idx
            self.duration = Double(self.queue[idx].duration ?? 0)
            self.preparedMixHint = nil
            self.activeTransitionPlan = nil
            self.listened = 0
            self.lastTick = 0
            self.songStart = Date()
            self.didScrobble = false
            self.saveState()
            if self.isPlaying {
                self.scrobbler?.nowPlaying(self.queue[idx], albumFallbackArtist: self.albumFallbackArtist(for: self.queue[idx]))
            }
            self.updateNowPlayingInfo()
            self.loadArtwork(for: self.queue[idx])
        }

        automixEngine.onTransitionCompleted = { [weak self] newSongId in
            guard let self else { return }
            if self.currentSong?.id != newSongId {
                let expectedIdx = self.nextAutoIndex()
                let resolvedIdx: Int?
                if let exp = expectedIdx, self.queue.indices.contains(exp), self.queue[exp].id == newSongId {
                    resolvedIdx = exp
                } else {
                    resolvedIdx = self.queue.firstIndex(where: { $0.id == newSongId })
                }
                if let idx = resolvedIdx {
                    self.consumePriority(movingTo: idx)
                    self.currentIndex = idx
                    self.duration = Double(self.queue[idx].duration ?? 0)
                    self.updateNowPlayingInfo()
                    self.loadArtwork(for: self.queue[idx])
                }
            }

            let finishedSongTitle = self.currentSong?.title ?? ""
            self.logEvent("MIX", "Transição concluída → \(finishedSongTitle)", detail: "Deck B assumiu como Deck principal sem interrupção.")

            // Deslize final da Capa B até o centro mentre a Capa A sai pela esquerda
            self.stageCoverArtB = self.currentSong?.coverArt
            self.coverStageMode = .settling
            self.stageSettleSafetyTask?.cancel()
            self.stageSettleSafetyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4.5))
                guard !Task.isCancelled else { return }
                self?.finishCoverStageSettling()
            }

            self.isAutomixing = false
            self.preparedMixHint = nil
            self.automixBadge = nil
            self.activeTransitionPlan = nil
            self.isPlaying = true
            if let cur = self.currentSong {
                self.songBecameActive(cur, resetListeningStats: false)
            }
        }

        automixEngine.onTrackEndedWithoutNext = { [weak self] in
            guard let self else { return }
            self.preparedMixHint = nil
            self.activeTransitionPlan = nil
            self.resetCoverStage()
            if !self.sleepAtEndOfTrack, let nextIdx = self.nextAutoIndex() {
                self.load(index: nextIdx, autoplay: true)
            } else {
                self.queueFinished()
            }
        }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let optRaw = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.isAudioSessionActive = false
                    if self.usingEngineMode { self.automixEngine.pause() }
                    self.isPlaying = false
                    self.updateNowPlayingProgress()
                } else if type == .ended, shouldResume {
                    self.activateSessionIfNeeded()
                    self.resume()
                }
            }
        }
        // Fones/Bluetooth desconectados: pausa; novo Bluetooth conectado: garante continuidade sem reiniciar a faixa
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable {
                    self.pause()
                } else if reason == .newDeviceAvailable || reason == .override || reason == .routeConfigurationChange {
                    if self.usingEngineMode && self.isPlaying && !self.automixEngine.isEngineRunning {
                        self.automixEngine.recoverAfterRouteChange()
                    }
                }
            }
        }
    }

    // MARK: Session

    private func configureSession() {
        let options: AVAudioSession.CategoryOptions = mixWithOtherApps ? [.mixWithOthers] : []
        Task.detached(priority: .userInitiated) {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default, options: options)
        }
    }

    private func activateSessionIfNeeded() {
        guard !isAudioSessionActive else { return }
        isAudioSessionActive = true
        AVAudioSession.sharedInstance().activate(options: []) { _, _ in }
    }

    private func deactivateSession() {
        guard isAudioSessionActive else { return }
        isAudioSessionActive = false
        AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in }
    }

    // MARK: Regras do Automix vs Gapless

    /// Álbuns ouvidos na sequência original mantêm Gapless puro; playlists, shuffle, listas
    /// e músicas inseridas manualmente na fila ("Tocar a seguir") usam Automix quando ativado.
    var shouldUseAutomix: Bool {
        guard automixEnabled, !sleepAtEndOfTrack else { return false }
        if !shuffle, priorityCount == 0, case .album = effectivePlaybackSource {
            return false
        }
        return true
    }

    func toggleAutomix() {
        automixEnabled.toggle()
    }

    /// Aplica o nível de compensação de volume ao vivo no motor Dual-Deck e no player Gapless.
    func applyVolumeCompensation(_ level: VolumeCompensationLevel) {
        automixEngine.volumeCompensation = level
        if !usingEngineMode {
            applyGaplessVolumeForCurrentSong(level: level)
        }
    }

    private func applyGaplessVolumeForCurrentSong(level: VolumeCompensationLevel? = nil) {
        let lvl = level ?? settings?.volumeCompensation ?? .off
        guard lvl != .off, let song = currentSong else {
            gaplessPlayer.volume = 1.0
            return
        }
        // AVQueuePlayer só atenua (<= 1.0), então normalizamos com teto em 1.0 quando está em Gapless
        func applyGain(_ gainDB: Float) {
            let linear = pow(10.0, gainDB / 20.0)
            gaplessPlayer.volume = min(max(linear, 0.35), 1.0)
        }
        if let localURL = localFileURL(for: song.id) {
            let songId = song.id
            if let cached = LoudnessCache.shared.get(songId) {
                applyGain(AutomixAudioEngine.computeGainDB(lufs: cached.lufs, peakDB: cached.peakDB, level: lvl))
                return
            }
            // A medição LUFS decodifica ~40 s de áudio (uma vez por faixa; depois fica no cache em disco)
            Task { [weak self] in
                let measured = await Task.detached(priority: .utility) { AutomixAudioEngine.measureLoudness(url: localURL) }.value
                guard let measured else { return }
                LoudnessCache.shared.set(songId, lufs: measured.lufs, peakDB: measured.peakDB)
                guard let self, self.currentSong?.id == songId else { return }
                applyGain(AutomixAudioEngine.computeGainDB(lufs: measured.lufs, peakDB: measured.peakDB, level: lvl))
            }
        } else if let energy = analysisStore?.metadata(for: song.id)?.energy, energy > 0.05 {
            let estRMS = Float(max(energy * 0.38, 0.02))
            let estDB = 20.0 * log10(estRMS)
            applyGain(AutomixAudioEngine.computeGainDB(lufs: estDB, peakDB: -1.0, level: lvl))
        } else {
            applyGain(0.0)
        }
    }

    /// Reativa o Modo DJ e reorganiza a fila inteira a partir da música que está tocando agora (sem interromper o áudio).
    /// `focus`/`families` mudam o foco de gênero da sessão antes de reordenar; sem eles, o foco atual é mantido.
    /// No modo "só gênero" a fila restante fica apenas com as famílias escolhidas (a fila original não é perdida).
    func enableAutomixAndReorganizeFromCurrent(focus: SmartShuffler.MixFocus? = nil, families: Set<GenreFamily>? = nil) {
        shuffle = true
        if !automixEnabled { automixEnabled = true }
        guard let current = currentSong else { return }
        if let focus {
            MixFocusPreference.record(focus)
            activeGenreFocus = SmartShuffler.GenreFocus.make(anchor: current, mode: focus, families: families)
        }

        let priorityStart = currentIndex + 1
        let priorityEnd = min(queue.count, priorityStart + priorityCount)
        let prioritySongs = priorityStart < priorityEnd ? Array(queue[priorityStart..<priorityEnd]) : []
        let priorityIds = Set(prioritySongs.map(\.id))

        let poolSource = originalQueue.count >= queue.count ? originalQueue : queue
        var seen: Set<String> = [current.id]
        seen.formUnion(priorityIds)
        var remaining = poolSource.filter { seen.insert($0.id).inserted }
        if focus == .strictGenre {
            remaining = filterForStrictGenre(remaining, families: activeGenreFocus.anchorFamilies, keeping: nil)
        }
        guard !remaining.isEmpty else {
            syncMetadataAndRefreshShuffleIfNeeded(source: playbackSource, originalCount: originalQueue.count)
            return
        }

        let anchor = prioritySongs.last ?? current
        let metadata = analysisStore?.items
        let gf = activeGenreFocus
        let token = beginBusy("Reorganizando a fila do Mix DJ")
        reorderTask?.cancel()
        reorderTask = Task { [weak self] in
            var smartTail: [Song]?
            var report: SmartShuffleRunLog?
            if let metadata {
                let result = await Task.detached(priority: .userInitiated) {
                    Self.smartOrder(songs: [anchor] + remaining, metadata: metadata, anchor: anchor, focus: gf)
                }.value
                smartTail = Array(result.queue.dropFirst())
                report = result.report
            }
            guard let self else { return }
            self.endBusy(token)
            guard !Task.isCancelled, self.currentSong?.id == current.id else { return }
            self.queue = [current] + prioritySongs + (smartTail ?? remaining.shuffled())
            self.currentIndex = 0
            self.playbackSource = .djMix(seedTitle: current.title)
            if let report { self.publishSmartShuffleLog(report, reason: "Modo DJ reorganizado a partir de \(current.title)") }
            self.queueChanged()
            self.syncMetadataAndRefreshShuffleIfNeeded(source: self.playbackSource, originalCount: self.originalQueue.count)
        }
    }

    // MARK: Playback control

    func play(songs: [Song], startAt index: Int = 0, source: PlaybackSource? = nil) {
        guard !songs.isEmpty, songs.indices.contains(index) else { return }
        queueBuildTask?.cancel()
        activeGenreFocus = pendingGenreFocus
        pendingGenreFocus = .none
        let chosen = songs[index]

        // Mix DJ: o Smart Shuffle (centenas de faixas, vários candidatos) roda fora da thread principal;
        // a interface continua responsiva e mostra o indicador de carregamento.
        if shuffle, automixEnabled, let store = analysisStore {
            let metadata = store.items
            let gf = activeGenreFocus
            let token = beginBusy("Montando a fila do Mix DJ")
            queueBuildTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Self.smartOrder(songs: songs, metadata: metadata, anchor: chosen, focus: gf)
                }.value
                guard let self else { return }
                self.endBusy(token)
                guard !Task.isCancelled else { return }
                self.playbackSource = source
                self.originalQueue = songs
                self.priorityCount = 0
                self.queue = result.queue
                self.publishSmartShuffleLog(result.report, reason: "Play com Smart Shuffle")
                self.load(index: 0)
                self.syncMetadataAndRefreshShuffleIfNeeded(source: source, originalCount: songs.count)
            }
            return
        }

        playbackSource = source
        originalQueue = songs
        priorityCount = 0
        if shuffle {
            var rest = songs
            rest.remove(at: index)
            queue = [chosen] + rest.shuffled()
            load(index: 0)
        } else {
            queue = songs
            load(index: index)
        }
        if automixEnabled {
            syncMetadataAndRefreshShuffleIfNeeded(source: source, originalCount: songs.count)
        }
    }

    func playAll(_ songs: [Song], shuffled: Bool = false, source: PlaybackSource? = nil) {
        guard !songs.isEmpty else { return }
        queueBuildTask?.cancel()
        activeGenreFocus = pendingGenreFocus
        pendingGenreFocus = .none
        shuffle = shuffled

        if shuffled, automixEnabled, let store = analysisStore {
            let metadata = store.items
            let gf = activeGenreFocus
            let token = beginBusy("Montando a fila do Mix DJ")
            queueBuildTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Self.smartOrder(songs: songs, metadata: metadata, anchor: nil, focus: gf)
                }.value
                guard let self else { return }
                self.endBusy(token)
                guard !Task.isCancelled else { return }
                self.playbackSource = source
                self.originalQueue = songs
                self.priorityCount = 0
                self.queue = result.queue
                self.publishSmartShuffleLog(result.report, reason: "Play All com Smart Shuffle")
                self.load(index: 0)
                self.syncMetadataAndRefreshShuffleIfNeeded(source: source, originalCount: songs.count)
            }
            return
        }

        playbackSource = source
        originalQueue = songs
        priorityCount = 0
        queue = shuffled ? songs.shuffled() : songs
        load(index: 0)
        if automixEnabled {
            syncMetadataAndRefreshShuffleIfNeeded(source: source, originalCount: songs.count)
        }
    }

    /// Foco de gênero do Mix DJ em andamento (famílias da faixa inicial). Reaplicado em toda reorganização da fila.
    @ObservationIgnored private(set) var activeGenreFocus: SmartShuffler.GenreFocus = .none
    /// Foco escolhido para o próximo `play`; consumido (e zerado) por ele.
    @ObservationIgnored private var pendingGenreFocus: SmartShuffler.GenreFocus = .none

    /// Toca um pool de gênero em ordem aleatória. Com `automix` o Smart Shuffle ordena para mixar e o motor
    /// dual-deck faz as transições; sem ele, reprodução gapless embaralhada.
    func playGenreMix(title: String, songs: [Song], automix: Bool) {
        guard !songs.isEmpty else { return }
        shuffle = true
        if automixEnabled != automix { automixEnabled = automix }
        play(songs: songs.shuffled(), startAt: 0, source: .djMix(seedTitle: title))
    }

    // MARK: Mix DJ a partir de uma faixa: foco de gênero

    /// Famílias de gênero de uma faixa, na ordem fixa do catálogo (sem "Outros").
    func genreFamilies(of song: Song) -> [GenreFamily] {
        let set = Set(GenreTaxonomy.tags(for: song).map(\.family)).subtracting([.other])
        return GenreFamily.allCases.filter { set.contains($0) }
    }

    /// Opções de foco de gênero para uma faixa de referência. Cada gênero da faixa pode ser escolhido sozinho
    /// ou em conjunto. `launch(modo, famílias)` roda a ação (iniciar um mix ou reordenar a fila).
    /// A escolha mais frequente do usuário vem marcada como sugestão.
    func genreFocusItems(for song: Song, launch: @escaping (SmartShuffler.MixFocus, Set<GenreFamily>?) -> Void) -> [ActionMenuItem] {
        let fams = genreFamilies(of: song)
        let preferred = MixFocusPreference.preferred

        func options(_ mode: SmartShuffler.MixFocus, verb: String, icon: String) -> [ActionMenuItem] {
            var list: [ActionMenuItem] = []
            if fams.count > 1 {
                list.append(ActionMenuItem(title: fams.map(\.rawValue).joined(separator: " + "), subtitle: "Todos os gêneros da faixa",
                                           systemImage: icon, style: .accent) { launch(mode, Set(fams)) })
            }
            for f in fams {
                list.append(ActionMenuItem(title: f.rawValue, systemImage: icon) { launch(mode, [f]) })
            }
            return list
        }

        var items: [ActionMenuItem] = []
        if !fams.isEmpty {
            let label = fams.map(\.rawValue).joined(separator: ", ")
            let focus = options(.genre, verb: "Focar", icon: "scope")
            let only = options(.strictGenre, verb: "Só", icon: "line.3.horizontal.decrease.circle")
            items.append(focus.count == 1
                ? ActionMenuItem(title: "Focar em \(label)", subtitle: "Prioriza o gênero; vizinhos entram só quando faltar",
                                 systemImage: "scope", style: .accent, isSelected: preferred == .genre, children: nil) { launch(.genre, Set(fams)) }
                : ActionMenuItem(title: "Focar em…", subtitle: "Prioriza o gênero escolhido; vizinhos entram só quando faltar",
                                 systemImage: "scope", style: .accent, isSelected: preferred == .genre, children: focus))
            items.append(only.count == 1
                ? ActionMenuItem(title: "Só \(label)", subtitle: "Deixa o resto da biblioteca de fora",
                                 systemImage: "line.3.horizontal.decrease.circle", isSelected: preferred == .strictGenre, children: nil) { launch(.strictGenre, Set(fams)) }
                : ActionMenuItem(title: "Só…", subtitle: "Deixa o resto da biblioteca de fora",
                                 systemImage: "line.3.horizontal.decrease.circle", isSelected: preferred == .strictGenre, children: only))
        }
        items.append(ActionMenuItem(title: "Variar entre gêneros", subtitle: "Só BPM, tom, vibe e energia",
                                    systemImage: "shuffle", isSelected: preferred == .variety) { launch(.variety, nil) })
        return items
    }

    /// Pergunta como montar a fila (focar num gênero da faixa, só ele, ou variar) e inicia o Mix DJ.
    /// `context == nil` usa a biblioteca inteira do servidor. Faixas sem gênero vão direto para "variar".
    func requestDJMix(startingWith song: Song, in context: [Song]?, source: PlaybackSource?) {
        let fams = genreFamilies(of: song)
        func launch(_ mode: SmartShuffler.MixFocus, _ chosen: Set<GenreFamily>?) {
            MixFocusPreference.record(mode)
            if let context {
                startDJMix(startingWith: song, in: context, source: source, focus: mode, families: chosen)
            } else {
                Task { await startFullLibraryDJMix(startingWith: song, focus: mode, families: chosen) }
            }
        }
        guard !fams.isEmpty else { launch(.variety, nil); return }

        let request = ActionMenuRequest(
            header: ActionMenuHeader(title: song.title, subtitle: "Gênero: \(fams.map(\.rawValue).joined(separator: ", "))", coverArt: song.coverArt),
            title: nil,
            message: "Como montar a fila a partir desta faixa?",
            sections: [genreFocusItems(for: song, launch: launch)]
        )
        // Espera o menu de origem terminar de fechar para os painéis não se atropelarem
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            self?.actionMenu = request
        }
    }

    /// Mantém só faixas das famílias escolhidas; se sobrarem poucas, soma famílias vizinhas.
    private func filterForStrictGenre(_ songs: [Song], families fams: Set<GenreFamily>, keeping anchorId: String?) -> [Song] {
        let fams = fams.subtracting([.other])
        guard !fams.isEmpty else { return songs }
        func shares(_ s: Song, _ target: Set<GenreFamily>) -> Bool {
            !Set(GenreTaxonomy.tags(for: s).map(\.family)).isDisjoint(with: target)
        }
        var out = songs.filter { $0.id == anchorId || shares($0, fams) }
        if out.count < GenreLibrary.minimumPool {
            let near = Set(fams.flatMap(\.neighbors)).subtracting(fams)
            let have = Set(out.map(\.id))
            let extra = songs.filter { !have.contains($0.id) && shares($0, near) }
            out += extra
            logEvent("SHUFFLE", "Só gênero: poucas faixas, ampliado com vizinhos", detail: "Foco: \(fams.map(\.rawValue).joined(separator: ", ")) • +\(extra.count) vizinhas")
        }
        return out
    }

    /// Inicia imediatamente um Mix DJ (Automix + Smart Shuffle) a partir de `song` usando a lista local (`contextSongs`).
    func startDJMix(startingWith song: Song, in contextSongs: [Song], source: PlaybackSource?,
                    focus: SmartShuffler.MixFocus = .variety, families: Set<GenreFamily>? = nil) {
        var pool = contextSongs.isEmpty ? [song] : contextSongs
        let chosenFamilies = families ?? Set(genreFamilies(of: song))
        if focus == .strictGenre { pool = filterForStrictGenre(pool, families: chosenFamilies, keeping: song.id) }
        let idx = pool.firstIndex(where: { $0.id == song.id }) ?? 0
        shuffle = true
        if !automixEnabled { automixEnabled = true }
        pendingGenreFocus = SmartShuffler.GenreFocus.make(anchor: song, mode: focus, families: families)
        play(songs: pool, startAt: idx, source: .djMix(seedTitle: song.title))
    }

    /// Inicia um Mix DJ (Automix + Smart Shuffle) a partir de `song` usando TODAS as músicas da biblioteca do servidor.
    func startFullLibraryDJMix(startingWith song: Song, focus: SmartShuffler.MixFocus = .variety, families: Set<GenreFamily>? = nil) async {
        guard let client else {
            startDJMix(startingWith: song, in: [song], source: .djMix(seedTitle: song.title), focus: focus, families: families)
            return
        }
        let token = beginBusy("Buscando a biblioteca completa")
        defer { endBusy(token) }
        async let syncTask: Void = {
            await self.analysisStore?.syncFromServerIfStale(mixClient: self.mixClient)
        }()

        var allSongs: [Song] = []
        var knownIds: Set<String> = []
        var offset = 0
        for _ in 0..<40 {
            guard let page = try? await client.songs(offset: offset, count: 500), !page.isEmpty else { break }
            let fresh = page.filter { knownIds.insert($0.id).inserted }
            if fresh.isEmpty { break }
            allSongs += fresh
            if page.count < 500 { break }
            offset += page.count
        }
        _ = await syncTask

        if allSongs.isEmpty {
            allSongs = [song]
        } else if !knownIds.contains(song.id) {
            allSongs.insert(song, at: 0)
        }
        if focus == .strictGenre {
            allSongs = filterForStrictGenre(allSongs, families: families ?? Set(genreFamilies(of: song)), keeping: song.id)
        }
        let idx = allSongs.firstIndex(where: { $0.id == song.id }) ?? 0
        shuffle = true
        if !automixEnabled { automixEnabled = true }
        pendingGenreFocus = SmartShuffler.GenreFocus.make(anchor: song, mode: focus, families: families)
        play(songs: allSongs, startAt: idx, source: .djMix(seedTitle: song.title))
    }

    private func syncMetadataAndRefreshShuffleIfNeeded(source: PlaybackSource?, originalCount: Int) {
        let beforeCount = analysisStore?.items.count ?? 0
        Task { [weak self] in
            guard let self else { return }
            await self.analysisStore?.syncFromServerIfStale(mixClient: self.mixClient)
            let afterCount = self.analysisStore?.items.count ?? 0
            if afterCount > beforeCount,
               self.automixEnabled,
               self.shuffle,
               self.playbackSource == source,
               self.originalQueue.count == originalCount {
                self.reorderUpcomingSmart(reason: "Fila atualizada após sync (\(afterCount) faixas IA)")
            }
        }
    }

    private func albumFallbackArtist(for song: Song) -> String? {
        if case .album(let alb) = playbackSource, alb.id == song.albumId || song.albumId == nil {
            return alb.artist
        }
        return nil
    }

    /// Acumula tempo ouvido (ignora seeks) e registra o scrobble ao atingir 50% ou 4 min.
    private func trackListening(_ t: Double) {
        let delta = t - lastTick
        lastTick = t
        guard isPlaying, !didScrobble, delta > 0, delta < 2, let song = currentSong,
              let dur = song.duration, dur > 30 else { return }
        listened += delta
        if listened >= min(Double(dur) / 2, 240) {
            didScrobble = true
            scrobbler?.scrobble(song, startedAt: songStart, albumFallbackArtist: albumFallbackArtist(for: song))
        }
    }

    private func consumePriority(movingTo index: Int) {
        if priorityCount > 0, index == currentIndex + 1 { priorityCount -= 1 } else { priorityCount = 0 }
    }

    /// Abre o arquivo local da faixa para o AVAudioEngine. Se o arquivo do cache recente estiver corrompido
    /// (ex.: download todo zerado), remove do cache para ser baixado de novo e registra no log do Automix.
    private func openEngineFile(for songId: String) -> AVAudioFile? {
        guard let url = localFileURL(for: songId) else { return nil }
        if let file = try? AVAudioFile(forReading: url), AutomixAudioEngine.canPlay(file: file) {
            return file
        }
        guard RecentSongsCache.isCorruptAudioFile(url) else { return nil }
        if downloads?.isDownloaded(songId) == true {
            logEvent("ENGINE", "Download corrompido", detail: "\(url.lastPathComponent) está zerado/vazio — remova e baixe a faixa novamente.")
        } else {
            recents?.evict(id: songId)
            logEvent("ENGINE", "Cache corrompido removido", detail: "\(url.lastPathComponent) estava zerado/vazio e será baixado novamente.")
        }
        return nil
    }

    func localFileURL(for songId: String) -> URL? {
        downloads?.localURL(for: songId) ?? recents?.localURL(for: songId)
    }

    func resolvedPlayableURL(for song: Song) -> URL? {
        let kbps = NetworkMonitor.shared.isExpensive ? settings?.cellularBitrate : settings?.wifiBitrate
        return localFileURL(for: song.id)
            ?? client?.streamURL(for: song.id, maxBitRate: (kbps ?? 0) > 0 ? kbps : nil)
    }

    private func makeGaplessItem(for index: Int) -> AVPlayerItem? {
        guard queue.indices.contains(index) else { return nil }
        let song = queue[index]
        guard let url = resolvedPlayableURL(for: song) else { return nil }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0
        itemIndex[ObjectIdentifier(item)] = index
        return item
    }

    /// Carrega uma faixa imediatamente:
    /// - Se `shouldUseAutomix` e o arquivo local já estiver em disco, inicia direto no `AutomixAudioEngine` (`AVAudioEngine`).
    /// - Caso contrário inicia instantaneamente no `gaplessPlayer` (`AVQueuePlayer`), baixando para o disco e migrando para o `AutomixAudioEngine` se o Automix estiver ativo!
    private func load(index: Int, autoplay: Bool = true) {
        automixPrepareTask?.cancel()
        automixEngine.stop()
        gaplessPlayer.pause()
        gaplessPlayer.removeAllItems()
        isAutomixing = false
        preparedMixHint = nil
        automixBadge = nil
        activeTransitionPlan = nil
        resetCoverStage()

        consumePriority(movingTo: index)
        guard queue.indices.contains(index) else { return }
        let song = queue[index]

        currentIndex = index
        currentTime = 0
        duration = Double(song.duration ?? 0)
        preloadedIndex = nil
        itemIndex = [:]
        activeItem = nil

        if autoplay {
            activateSessionIfNeeded()
        }

        if shouldUseAutomix,
           let audioFile = openEngineFile(for: song.id) {
            usingEngineMode = true
            automixEngine.volumeCompensation = settings?.volumeCompensation ?? .off
            automixEngine.startPlaying(file: audioFile, songId: song.id, startAtSec: 0, autoplay: autoplay)
            isPlaying = autoplay
        } else {
            usingEngineMode = false
            guard let item = makeGaplessItem(for: index) else { return }
            itemIndex = [ObjectIdentifier(item): index]
            activeItem = item
            applyGaplessVolumeForCurrentSong()
            gaplessPlayer.insert(item, after: nil)
            if autoplay { gaplessPlayer.play() }
            isPlaying = autoplay
        }

        updateNowPlayingInfo()
        loadArtwork(for: song)
        songBecameActive(song)
        preloadNextInGapless()
    }

    private func songBecameActive(_ song: Song, resetListeningStats: Bool = true) {
        if resetListeningStats {
            listened = 0; lastTick = 0; songStart = Date(); didScrobble = false
            saveState()
            if isPlaying { scrobbler?.nowPlaying(song, albumFallbackArtist: albumFallbackArtist(for: song)) }
        }

        if let local = localFileURL(for: song.id) {
            analysisStore?.analyzeIfNeeded(songId: song.id, localURL: local)
        }

        automixPrepareTask?.cancel()
        let nextIdx = nextAutoIndex()
        let nextSong = nextIdx.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
        let lookaheadSongs = (1...3).compactMap { offset -> Song? in
            let idx = currentIndex + offset
            return queue.indices.contains(idx) ? queue[idx] : nil
        }
        let protected = Set([song.id] + lookaheadSongs.map(\.id))

        automixPrepareTask = Task {
            // 1. Se o Automix está ativo mas esta música começou via stream HTTP (não estava local ainda),
            //    baixa ela primeiro para migrar perfeitamente para o AVAudioEngine antes da virada!
            if shouldUseAutomix && !usingEngineMode {
                if downloads?.isDownloaded(song.id) != true {
                    await recents?.cache(song, protecting: protected, forceForAutomix: true)
                }
                guard !Task.isCancelled, currentSong?.id == song.id else { return }
                if let localA = localFileURL(for: song.id),
                   let fileA = openEngineFile(for: song.id) {
                    _ = await analysisStore?.ensureAnalyzed(songId: song.id, localURL: localA)
                    guard !Task.isCancelled, currentSong?.id == song.id, shouldUseAutomix else { return }
                    let posSec = currentTime
                    let wasPlaying = isPlaying
                    if posSec < max(duration - 12.0, 8.0) {
                        gaplessPlayer.pause()
                        gaplessPlayer.removeAllItems()
                        activeItem = nil
                        preloadedIndex = nil
                        usingEngineMode = true
                        automixEngine.startPlaying(file: fileA, songId: song.id, startAtSec: posSec, autoplay: wasPlaying)
                    }
                }
            } else if downloads?.isDownloaded(song.id) != true {
                await recents?.cache(song, protecting: protected, forceForAutomix: false)
                if let localA = localFileURL(for: song.id) {
                    analysisStore?.analyzeIfNeeded(songId: song.id, localURL: localA)
                }
            }

            guard !Task.isCancelled, currentSong?.id == song.id else { return }

            // 2. Se estamos rodando no AutomixAudioEngine, prepara o Deck B com arquivo local + TransitionPlan JSON do servidor
            if shouldUseAutomix, usingEngineMode, let nextSong {
                await prepareIncomingAutomix(from: song, to: nextSong, protecting: protected)
            }

            // 3. Pré-cache das próximas faixas da janela
            for cand in lookaheadSongs.dropFirst() {
                guard !Task.isCancelled else { break }
                if downloads?.isDownloaded(cand.id) != true {
                    await recents?.cache(cand, protecting: protected, forceForAutomix: shouldUseAutomix)
                }
                if let localC = localFileURL(for: cand.id) {
                    analysisStore?.analyzeIfNeeded(songId: cand.id, localURL: localC)
                }
            }
        }
    }

    private func onAutomixEnabledMidTrack() {
        guard let song = currentSong else { return }
        if !usingEngineMode {
            if let fileA = openEngineFile(for: song.id) {
                let posSec = currentTime
                let wasPlaying = isPlaying
                gaplessPlayer.pause()
                gaplessPlayer.removeAllItems()
                activeItem = nil
                preloadedIndex = nil
                usingEngineMode = true
                automixEngine.startPlaying(file: fileA, songId: song.id, startAtSec: posSec, autoplay: wasPlaying)
                if let nextSong = nextSongInQueue {
                    automixPrepareTask?.cancel()
                    automixPrepareTask = Task {
                        await prepareIncomingAutomix(from: song, to: nextSong, protecting: [song.id, nextSong.id])
                    }
                }
            } else {
                // Baixa e migra para o AVAudioEngine
                songBecameActive(song)
            }
        } else if let nextSong = nextSongInQueue {
            automixPrepareTask?.cancel()
            automixPrepareTask = Task {
                await prepareIncomingAutomix(from: song, to: nextSong, protecting: [song.id, nextSong.id])
            }
        }
    }

    /// Re-arma o plano imediatamente se o usuário acabou de salvar/remover uma receita para o par atual.
    func reprepareCurrentPairIfMatching(from idA: String, to idB: String) {
        guard currentSong?.id == idA, nextSongInQueue?.id == idB else { return }
        reprepareIncomingIfNeeded()
    }

    /// Reproduz o par `(songA → songB)` em modo DJ e posiciona alguns segundos antes do ponto de mixagem
    /// para o usuário auditar a transição imediatamente com a receita configurada.
    func auditionTransition(from songA: Song, to songB: Song) {
        auditionTask?.cancel()
        queueBuildTask?.cancel()
        shuffle = false
        if !automixEnabled { automixEnabled = true }
        playbackSource = .djMix(seedTitle: "Auditoria")
        originalQueue = [songA, songB]
        priorityCount = 0
        queue = [songA, songB]
        load(index: 0, autoplay: true)

        auditionTask = Task { [weak self] in
            guard let self else { return }
            // Aguarda o motor armar o plano de transição (incluindo receita personalizada)
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                if let plan = self.activeTransitionPlan,
                   plan.trackA.id == songA.id,
                   plan.trackB.id == songB.id,
                   self.usingEngineMode {
                    let leadBeforeMix = max(0.0, plan.trackA.mixStartSec - 8.0)
                    let targetSec: Double
                    if abs(plan.sync.targetRateA - 1.0) >= 0.003,
                       plan.trackA.rampStartSec < plan.trackA.mixStartSec,
                       plan.trackA.mixStartSec - plan.trackA.rampStartSec <= 14.0 {
                        targetSec = max(0.0, plan.trackA.rampStartSec - 1.5)
                    } else {
                        targetSec = leadBeforeMix
                    }
                    if targetSec > 1.0 {
                        self.seek(to: targetSec)
                    }
                    return
                }
            }
        }
    }

    private func reprepareIncomingIfNeeded() {
        guard shouldUseAutomix, usingEngineMode, !isAutomixing,
              let song = currentSong, let nextSong = nextSongInQueue else { return }
        automixPrepareTask?.cancel()
        automixPrepareTask = Task {
            await prepareIncomingAutomix(from: song, to: nextSong, protecting: [song.id, nextSong.id])
        }
    }

    private func applyUserAutomixOverrides(
        to rawPlan: TransitionPlan,
        pairOverride: TransitionOverride? = nil,
        durationA: Double? = nil,
        durationB: Double? = nil
    ) -> TransitionPlan {
        var plan = rawPlan

        // Prioridade: Receita personalizada do par (A → B) > Ajuste global do usuário > Sugestão automática do servidor/local.
        let effectiveVolumeCurve: AutomixVolumeCurve = {
            if let pairOverride, pairOverride.volumeCurve != .auto { return pairOverride.volumeCurve }
            return automixVolumeCurve
        }()
        if effectiveVolumeCurve != .auto {
            plan.mix.volumeCurve = effectiveVolumeCurve.rawValue
        } else if (plan.mix.volumeCurve ?? "").isEmpty {
            plan.mix.volumeCurve = AutomixVolumeCurve.overlap.rawValue
        }

        let effectiveEQStyle: AutomixEQStyle = {
            if let pairOverride, pairOverride.eqStyle != .auto { return pairOverride.eqStyle }
            return automixEQStyle
        }()
        if effectiveEQStyle != .auto {
            plan.mix.eqStyle = effectiveEQStyle.rawValue
        } else if (plan.mix.eqStyle ?? "").isEmpty {
            plan.mix.eqStyle = AutomixEQStyle.centerBassSwap.rawValue
        }

        let effectiveFilterStyle: AutomixFilterStyle = {
            if let pairOverride, pairOverride.filterStyle != .auto { return pairOverride.filterStyle }
            return automixFilterStyle
        }()
        if effectiveFilterStyle != .auto {
            plan.mix.filterStyle = effectiveFilterStyle.rawValue
        } else if (plan.mix.filterStyle ?? "").isEmpty {
            plan.mix.filterStyle = AutomixFilterStyle.hpInHpOut.rawValue
        }

        // Garante corte real de graves (-24 dB) para o EQ entrar no meio da transição mesmo em faixas com BPM distante
        if plan.mix.eqSwap.bassCutDb > -18.0 {
            plan.mix.eqSwap.bassCutDb = -24.0
        }

        // Reverb opcional (receita do par pode forçar ligado ou desligado)
        if let pairOverride, pairOverride.reverbChoice != .auto {
            plan.mix.reverbTail = (pairOverride.reverbChoice == .on)
        } else if automixReverbEnabled {
            plan.mix.reverbTail = true
        }

        let bpmA = max(plan.trackA.bpm, 65.0)
        let bpmB = max(plan.trackB.bpm, 65.0)
        let rateA = Double(max(plan.sync.targetRateA, 0.75))
        let barSecA = 4.0 * 60.0 / bpmA
        let barSecB = 4.0 * 60.0 / bpmB
        let durA = (durationA ?? 0) > 0 ? (durationA ?? 0) : (duration > 0 ? duration : max(plan.trackA.mixEndSec + 10.0, 120.0))
        let maxEnd = max(4.0, durA - 0.25)

        // Deslocamento personalizado do ponto de entrada de B em compassos inteiros
        if let pairOverride, pairOverride.entryOffsetBars != 0 {
            let shiftedEntry = plan.trackB.entrySec + Double(pairOverride.entryOffsetBars) * barSecB
            let maxEntryB: Double
            if let durB = durationB, durB > 12.0 {
                maxEntryB = durB - 8.0
            } else {
                maxEntryB = max(shiftedEntry, 0.0)
            }
            plan.trackB.entrySec = min(max(0.0, shiftedEntry), maxEntryB)
        }

        // Deslocamento personalizado do ponto de saída de A em compassos inteiros
        let pairStartOffsetBars = pairOverride?.mixStartOffsetBars ?? 0
        let pairDurationChoice = pairOverride?.durationChoice ?? .auto
        let effectiveDurationChoice = pairDurationChoice != .auto ? pairDurationChoice : automixDurationChoice
        let userFixedBars = effectiveDurationChoice != .auto
        let needsTimingRecalc = (pairStartOffsetBars != 0)
            || (pairDurationChoice != .auto)
            || (plan.source != "allin1" && (plan.transitionType == "beatmatch" || userFixedBars))

        if needsTimingRecalc {
            let currentSpan = max(barSecA * 2.0, plan.trackA.mixEndSec - plan.trackA.mixStartSec)
            let requestedBars = userFixedBars
                ? effectiveDurationChoice.rawValue
                : (plan.mix.bars ?? max(2, Int((currentSpan / barSecA).rounded())))

            var newStart = plan.trackA.mixStartSec + Double(pairStartOffsetBars) * barSecA
            newStart = max(0.0, min(newStart, max(0.0, maxEnd - 2.0 * barSecA)))

            var bars = max(requestedBars, 2)
            while bars > 2 && newStart + Double(bars) * barSecA > maxEnd {
                bars = max(bars / 2, 2)
            }
            if newStart + Double(bars) * barSecA > maxEnd {
                let overflow = newStart + Double(bars) * barSecA - maxEnd
                newStart = max(0.0, newStart - ceil(overflow / barSecA) * barSecA)
            }
            let newEnd = min(maxEnd, newStart + Double(bars) * barSecA)

            let barsChanged = plan.mix.bars != bars
            let startMoved = abs(newStart - plan.trackA.mixStartSec) > 0.001
            if barsChanged || startMoved || abs(newEnd - plan.trackA.mixEndSec) > 0.001 {
                plan.trackA.mixStartSec = newStart
                plan.trackA.mixEndSec = newEnd
                if (userFixedBars && barsChanged) || startMoved,
                   plan.trackA.rampStartSec > newStart - 2.0 * barSecA {
                    plan.trackA.rampStartSec = max(durA * 0.38, newStart - 8.0 * barSecA)
                    if plan.trackA.rampStartSec > newStart {
                        plan.trackA.rampStartSec = max(0.0, newStart - 4.0 * barSecA)
                    }
                }
                plan.trackA.rampStartSec = min(plan.trackA.rampStartSec, newStart)
                if abs(plan.sync.targetRateA - 1.0) >= 0.003 {
                    let availLead = max(0.0, newStart - plan.trackA.rampStartSec)
                    plan.sync.rampDurationSec = min(max(plan.sync.rampDurationSec, min(availLead, 4.0 * barSecA)), availLead)
                }
                plan.mix.bars = bars
                plan.mix.durationSec = max(2.0, (newEnd - newStart) / rateA)
            }
        }
        return plan
    }

    /// Baixa a Faixa B para o disco (se necessário), busca o `TransitionPlan` do servidor `allin1` (:4534)
    /// (com fallback para cálculo local) e agenda no `AutomixAudioEngine`.
    private func prepareIncomingAutomix(from songA: Song, to songB: Song, protecting: Set<String>) async {
        if downloads?.isDownloaded(songB.id) != true {
            await recents?.cache(songB, protecting: protecting, forceForAutomix: true)
        }
        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }

        var openedB = openEngineFile(for: songB.id)
        if openedB == nil, localFileURL(for: songB.id) == nil {
            // O arquivo estava corrompido e saiu do cache: baixa de novo antes de desistir do mix
            await recents?.cache(songB, protecting: protecting, forceForAutomix: true)
            guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
            openedB = openEngineFile(for: songB.id)
        }
        guard let fileB = openedB, let localB = localFileURL(for: songB.id) else {
            logEvent("ENGINE", "Mix não armado: \(songB.title)", detail: "O arquivo local da próxima faixa não pôde ser aberto pelo AVAudioEngine (formato não suportado ou download falhou).")
            return
        }

        let pairOverride = transitionAudit?.override(from: songA.id, to: songB.id)
        let appliedOverride = pairOverride?.hasParameterCustomizations ?? false
        let barsOverride: Int? = {
            if let pairOverride, pairOverride.durationChoice != .auto {
                return pairOverride.durationChoice.rawValue
            }
            return automixDurationChoice == .auto ? nil : automixDurationChoice.rawValue
        }()
        let durA = duration > 0 ? duration : Double(songA.duration ?? 180)

        // Busca TransitionPlan calculado pelo servidor allin1 (ou monta localmente se servidor estiver offline/ocupado)
        let rawPlan: TransitionPlan
        if let mixClient, let serverPlan = try? await mixClient.fetchTransition(from: songA.id, to: songB.id, barsOverride: barsOverride) {
            rawPlan = serverPlan
        } else {
            if let localA = localFileURL(for: songA.id) {
                _ = await analysisStore?.ensureAnalyzed(songId: songA.id, localURL: localA)
            }
            _ = await analysisStore?.ensureAnalyzed(songId: songB.id, localURL: localB)
            rawPlan = SmartShuffler.buildLocalTransitionPlan(
                idA: songA.id,
                metaA: analysisStore?.metadata(for: songA.id),
                idB: songB.id,
                metaB: analysisStore?.metadata(for: songB.id),
                durationA: durA
            )
        }

        var plan = applyUserAutomixOverrides(
            to: rawPlan,
            pairOverride: pairOverride,
            durationA: durA,
            durationB: Double(songB.duration ?? 0)
        )

        // Plano local (offline): confere o BPM real no PCM das duas faixas, porque a análise local é aproximada.
        // Planos do servidor já trazem o BPM exato da grade constante e são executados sem alteração.
        if plan.transitionType == "beatmatch", plan.source != "allin1", let localA = localFileURL(for: songA.id) {
            let basePlan = plan
            plan = await Task.detached(priority: .userInitiated) {
                AutomixAudioEngine.refineTransitionPlanWithTrueBPM(plan: basePlan, urlA: localA, urlB: localB)
            }.value
        }

        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
        if let coverB = songB.coverArt {
            _ = await ImageCache.shared.image(id: coverB, size: 600, client: client)
        }
        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
        let preparedPlan = await automixEngine.prepareIncoming(fileB: fileB, songId: songB.id, plan: plan)
        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
        let resolvedPlan = preparedPlan ?? plan
        activeTransitionPlan = resolvedPlan
        preparedPairContext = (from: songA, to: songB, appliedOverride: appliedOverride)

        let outStr = Self.formatMMSS(resolvedPlan.trackA.mixStartSec)
        let inStr = Self.formatMMSS(resolvedPlan.trackB.entrySec)
        let tag = appliedOverride ? "RECEITA" : ((resolvedPlan.source == "allin1") ? "MIX IA" : "MIX LOCAL")
        let barsTxt = resolvedPlan.mix.bars.map { "\($0)c" } ?? ""
        let volShort = AutomixVolumeCurve(rawValue: resolvedPlan.mix.volumeCurve ?? "")?.shortLabel ?? "SOBREPOR"
        let eqShort = AutomixEQStyle(rawValue: resolvedPlan.mix.eqStyle ?? "")?.shortLabel ?? "EQ CENTRAL"
        let fltShort = AutomixFilterStyle(rawValue: resolvedPlan.mix.filterStyle ?? "")?.shortLabel ?? ""
        let fxSummary = fltShort.isEmpty ? "\(volShort) • \(eqShort)" : "\(volShort) • \(eqShort) • \(fltShort)"
        preparedMixHint = "\(tag) (\(barsTxt)) • \(outStr)→\(inStr) • \(fxSummary)"

        // Badge armado discreto (mostra direção prevista do BPM quando em espera)
        if !isAutomixing {
            let r = resolvedPlan.sync.targetRateA
            let icon = r > 1.003 ? "arrowtriangle.up.fill" : (r < 0.997 ? "arrowtriangle.down.fill" : "waveform")
            automixBadge = AutomixIndicatorBadge(text: "SYNC \(outStr)", icon: icon, kind: .armed)
        }

        logEvent(
            appliedOverride ? "AUDITORIA" : (resolvedPlan.source == "allin1" ? "SERVIDOR" : "ENGINE"),
            "Plano armado: \(songA.title) → \(songB.title)",
            detail: "\(tag) (\(resolvedPlan.mix.bars ?? 8) comp.) | Saída \(outStr) [\(resolvedPlan.trackA.section ?? "inst")] → Entrada \(inStr) [\(resolvedPlan.trackB.section ?? "drop")] | Rate A: \(String(format: "%.3fx", resolvedPlan.sync.targetRateA)) • Rate B: \(String(format: "%.3fx", resolvedPlan.sync.initialRateB ?? 1.0)) | \(fxSummary)"
        )
    }

    private static func activeMixingBadge(for plan: TransitionPlan?) -> AutomixIndicatorBadge {
        guard let plan else {
            return AutomixIndicatorBadge(text: "MIX", icon: "waveform", kind: .mixOverlap)
        }
        if plan.transitionType != "beatmatch" && plan.mix.filterStyle == AutomixFilterStyle.finalNoiseOut.rawValue {
            return AutomixIndicatorBadge(text: "MIX • WASH", icon: "aqi.medium", kind: .mixFilterWash)
        }
        if plan.mix.filterStyle == AutomixFilterStyle.finalNoiseOut.rawValue || plan.mix.reverbTail == true {
            return AutomixIndicatorBadge(text: "MIX • FX", icon: "sparkles", kind: .mixFilterWash)
        }
        let eq = AutomixEQStyle(rawValue: plan.mix.eqStyle ?? "") ?? .centerBassSwap
        let vol = AutomixVolumeCurve(rawValue: plan.mix.volumeCurve ?? "") ?? .overlap

        if eq == .threeBandTransition {
            return AutomixIndicatorBadge(text: "MIX • 3B", icon: "slider.horizontal.3", kind: .mixThreeBand)
        }
        if vol == .cutInFadeOut || vol == .fadeInCutOut || vol == .centerCut || vol == .crossfadeQuickOut || vol == .fadeIn1BarCutOut || vol == .overlap1BarCutOut || eq == .quickBassCut {
            return AutomixIndicatorBadge(text: "MIX • CORTE", icon: "bolt.fill", kind: .mixQuickCut)
        }
        if vol == .smoothCrossfade || vol == .fadeInFadeOut {
            return AutomixIndicatorBadge(text: "MIX • FADE", icon: "waveform", kind: .mixFade)
        }
        return AutomixIndicatorBadge(text: "MIX • EQ", icon: "waveform.path.ecg", kind: .mixOverlap)
    }

    private static func formatMMSS(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Índice da próxima faixa em reprodução contínua (nil = fim da fila).
    private func nextAutoIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .one { return currentIndex }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// Mantém 1 faixa pré-carregada no `gaplessPlayer` quando no modo Gapless puro.
    private func preloadNextInGapless() {
        guard !usingEngineMode else { return }
        for extra in gaplessPlayer.items().dropFirst() { gaplessPlayer.remove(extra) }
        preloadedIndex = nil
        guard !sleepAtEndOfTrack, let next = nextAutoIndex(), let item = makeGaplessItem(for: next) else { return }
        if gaplessPlayer.canInsert(item, after: nil) {
            gaplessPlayer.insert(item, after: nil)
            preloadedIndex = next
        }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        guard let item, item !== activeItem, let idx = itemIndex[ObjectIdentifier(item)] else { return }
        consumePriority(movingTo: idx)
        activeItem = item
        currentIndex = idx
        currentTime = 0
        duration = Double(queue[idx].duration ?? 0)
        itemIndex = itemIndex.filter { $0.key == ObjectIdentifier(item) }
        isPlaying = true
        updateNowPlayingInfo()
        loadArtwork(for: queue[idx])
        songBecameActive(queue[idx])
        preloadNextInGapless()
    }

    private func queueFinished() {
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            load(index: nextAutoIndex() ?? 0, autoplay: false)
            return
        }
        load(index: 0, autoplay: false)
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard currentSong != nil else { return }
        activateSessionIfNeeded()
        if usingEngineMode {
            automixEngine.resume()
        } else {
            gaplessPlayer.play()
        }
        isPlaying = true
        updateNowPlayingProgress()
    }

    func pause() {
        if usingEngineMode {
            automixEngine.pause()
        } else {
            gaplessPlayer.pause()
        }
        isPlaying = false
        updateNowPlayingProgress()
        saveState()
    }

    func next() {
        guard !queue.isEmpty else { return }
        load(index: currentIndex + 1 < queue.count ? currentIndex + 1 : 0)
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        if currentIndex > 0 { load(index: currentIndex - 1) } else { seek(to: 0) }
    }

    func seek(to seconds: Double) {
        let existingPlan = activeTransitionPlan
        let clampedSeconds: Double
        if shouldUseAutomix, let plan = existingPlan, plan.trackA.mixStartSec > 4.0 {
            // Se o usuário arrastou até perto ou depois do ponto de mixagem, posiciona 3 s antes
            // para ele assistir à rampa de BPM + transição completa sem perdê-la!
            let previewLead = min(3.0, max(1.5, plan.trackA.mixStartSec * 0.15))
            clampedSeconds = min(max(0.0, seconds), max(0.0, plan.trackA.mixStartSec - previewLead))
        } else {
            clampedSeconds = max(0.0, seconds)
        }
        currentTime = clampedSeconds
        if usingEngineMode {
            isAutomixing = false
            resetCoverStage()
            automixEngine.seek(to: clampedSeconds)
            if shouldUseAutomix, let cur = currentSong, let nextSong = nextSongInQueue {
                // Reaproveita imediatamente o plano já armado em memória (0 ms de espera de rede)
                if let plan = existingPlan,
                   plan.trackA.id == cur.id,
                   plan.trackB.id == nextSong.id,
                   let fileB = openEngineFile(for: nextSong.id) {
                    automixPrepareTask?.cancel()
                    automixPrepareTask = Task {
                        let preparedPlan = await automixEngine.prepareIncoming(fileB: fileB, songId: nextSong.id, plan: plan)
                        guard !Task.isCancelled, currentSong?.id == cur.id else { return }
                        activeTransitionPlan = preparedPlan ?? plan
                    }
                } else {
                    preparedMixHint = nil
                    activeTransitionPlan = nil
                    automixBadge = nil
                    automixPrepareTask?.cancel()
                    automixPrepareTask = Task {
                        await prepareIncomingAutomix(from: cur, to: nextSong, protecting: [cur.id, nextSong.id])
                    }
                }
            } else {
                preparedMixHint = nil
                activeTransitionPlan = nil
                automixBadge = nil
            }
        } else {
            gaplessPlayer.seek(to: CMTime(seconds: clampedSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlayingProgress()
    }

    func scrubbing(_ active: Bool) { isScrubbing = active }

    func toggleShuffle() {
        shuffle.toggle()
        if !shuffle { reorderTask?.cancel() }
        guard !queue.isEmpty, let current = currentSong else { return }
        let priorityEnd = min(currentIndex + 1 + priorityCount, queue.count)
        let prioritySongs = currentIndex + 1 < priorityEnd ? Array(queue[(currentIndex + 1)..<priorityEnd]) : []

        if shuffle {
            let base = originalQueue.isEmpty ? queue : originalQueue
            var excludedIds = Set([current.id] + prioritySongs.map(\.id))
            var remaining: [Song] = []
            for s in base {
                if excludedIds.remove(s.id) != nil { continue }
                remaining.append(s)
            }
            if automixEnabled, let store = analysisStore {
                let anchor = prioritySongs.last ?? current
                let metadata = store.items
                let gf = activeGenreFocus
                let token = beginBusy("Montando a fila aleatória")
                reorderTask?.cancel()
                reorderTask = Task { [weak self] in
                    let result = await Task.detached(priority: .userInitiated) {
                        Self.smartOrder(songs: [anchor] + remaining, metadata: metadata, anchor: anchor, focus: gf)
                    }.value
                    guard let self else { return }
                    self.endBusy(token)
                    guard !Task.isCancelled, self.shuffle, self.currentSong?.id == current.id else { return }
                    self.queue = [current] + prioritySongs + Array(result.queue.dropFirst())
                    self.currentIndex = 0
                    self.publishSmartShuffleLog(result.report, reason: "Ativou Aleatório Inteligente")
                    self.syncMetadataAndRefreshShuffleIfNeeded(source: self.playbackSource, originalCount: self.originalQueue.count)
                    self.queueChanged()
                }
                return
            }
            queue = [current] + prioritySongs + remaining.shuffled()
            currentIndex = 0
        } else if !originalQueue.isEmpty {
            var restored = originalQueue
            let newIdx = restored.firstIndex(where: { $0.id == current.id }) ?? 0
            if !prioritySongs.isEmpty {
                restored.insert(contentsOf: prioritySongs, at: min(newIdx + 1, restored.count))
            }
            queue = restored
            currentIndex = newIdx
        }
        queueChanged()
    }

    /// Reorganiza as próximas faixas da fila aleatória com `SmartShuffler` (em segundo plano, sem travar a interface).
    private func reorderUpcomingSmart(reason: String = "Reordenou fila para Automix") {
        guard shuffle, let store = analysisStore, let current = currentSong,
              currentIndex + 1 + priorityCount < queue.count else { return }
        let keepEnd = currentIndex + 1 + priorityCount
        let keptPrefix = Array(queue[0..<keepEnd])
        let tail = Array(queue[keepEnd..<queue.count])
        let anchor = keptPrefix.last ?? current
        let metadata = store.items
        let snapshotCount = queue.count
        let snapshotIndex = currentIndex
        let reportFrom = currentIndex
        let gf = activeGenreFocus
        reorderTask?.cancel()
        reorderTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (queue: [Song], report: SmartShuffleRunLog) in
                let smartTail = SmartShuffler.smartShuffle(songs: [anchor] + tail, metadata: metadata, startingWith: anchor, genreFocus: gf).dropFirst()
                let full = keptPrefix + Array(smartTail)
                return (full, SmartShuffler.buildShuffleReport(orderedSongs: Array(full[reportFrom..<full.count]), metadata: metadata))
            }.value
            guard let self, !Task.isCancelled,
                  self.queue.count == snapshotCount, self.currentIndex == snapshotIndex,
                  self.currentSong?.id == current.id else { return }
            self.queue = result.queue
            self.publishSmartShuffleLog(result.report, reason: reason)
            self.queueChanged()
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        queueChanged()
    }

    // MARK: Fila (queue)

    /// Faixas que vêm depois da atual, com o índice real na fila.
    var upcoming: [(index: Int, song: Song)] {
        guard currentIndex + 1 < queue.count else { return [] }
        return (currentIndex + 1..<queue.count).map { ($0, queue[$0]) }
    }

    /// Reconstrói o pré-carregamento (Gapless ou Automix Deck B) depois de qualquer alteração na fila.
    private func queueChanged() {
        saveState()
        if usingEngineMode {
            automixPrepareTask?.cancel()
            automixEngine.clearPreparedIncoming()
            preparedMixHint = nil
            activeTransitionPlan = nil
            if coverStageMode == .ramping {
                resetCoverStage()
            }
            if shouldUseAutomix, let cur = currentSong, let nextSong = nextSongInQueue {
                automixPrepareTask = Task {
                    await prepareIncomingAutomix(from: cur, to: nextSong, protecting: [cur.id, nextSong.id])
                }
            }
        } else {
            itemIndex = activeItem.map { [ObjectIdentifier($0): currentIndex] } ?? [:]
            preloadNextInGapless()
        }
    }

    func playNext(_ song: Song) {
        guard currentSong != nil else { play(songs: [song]); return }
        queue.insert(song, at: currentIndex + 1)
        priorityCount += 1
        promoteToEngineForQueuedMixIfNeeded()
        queueChanged()
    }

    func addToQueue(_ song: Song) {
        guard currentSong != nil else { play(songs: [song]); return }
        queue.append(song)
        if !originalQueue.isEmpty { originalQueue.append(song) }
        // Se a faixa recém-adicionada virou a próxima imediata (ex.: fila só tinha 1 música), tenta mixar
        if currentIndex + 1 == queue.count - 1 {
            promoteToEngineForQueuedMixIfNeeded()
        }
        queueChanged()
    }

    /// Se o Automix estiver ligado mas a faixa atual estiver tocando em Gapless (ex.: álbum sem shuffle ou stream),
    /// promove a faixa atual para o motor Dual-Deck no tempo exato para tentar mixar a faixa inserida na fila.
    private func promoteToEngineForQueuedMixIfNeeded() {
        guard shouldUseAutomix, !usingEngineMode, let cur = currentSong else { return }
        if let audioFile = openEngineFile(for: cur.id) {
            let resumeSec = max(0, currentTime)
            let wasPlaying = isPlaying
            gaplessPlayer.pause()
            gaplessPlayer.removeAllItems()
            itemIndex = [:]
            activeItem = nil
            usingEngineMode = true
            automixEngine.volumeCompensation = settings?.volumeCompensation ?? .off
            automixEngine.startPlaying(file: audioFile, songId: cur.id, startAtSec: resumeSec, autoplay: wasPlaying)
        } else {
            // Ainda não está em cache local: baixa em segundo plano e promove assim que disponível
            let curId = cur.id
            Task { [weak self] in
                guard let self else { return }
                await self.recents?.cache(cur, protecting: [curId], forceForAutomix: true)
                guard self.currentSong?.id == curId, self.shouldUseAutomix, !self.usingEngineMode else { return }
                self.promoteToEngineForQueuedMixIfNeeded()
                self.queueChanged()
            }
        }
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        load(index: index)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        if priorityCount > 0, index > currentIndex, index <= currentIndex + priorityCount { priorityCount -= 1 }
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        queueChanged()
    }

    /// `source`/`destination` são índices reais da fila (apenas a parte "a seguir" é reordenável).
    func moveInQueue(from source: IndexSet, to destination: Int) {
        var order = Array(queue.indices)
        let moving = source.sorted().map { order[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { order.remove(at: i) }
        order.insert(contentsOf: moving, at: destination - before)
        guard let newCurrent = order.firstIndex(of: currentIndex) else { return }
        queue = order.map { queue[$0] }
        currentIndex = newCurrent
        priorityCount = 0
        queueChanged()
    }

    func clearUpcoming() {
        guard currentIndex + 1 < queue.count else { return }
        queue.removeSubrange((currentIndex + 1)...)
        priorityCount = 0
        queueChanged()
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEnd = nil
        if sleepAtEndOfTrack { sleepAtEndOfTrack = false; queueChanged() }
        guard let minutes else { return }
        sleepEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepEnd = nil
        }
    }

    func sleepAfterCurrentTrack() {
        setSleepTimer(minutes: nil)
        sleepAtEndOfTrack = true
        queueChanged()
    }

    func cancelSleep() { setSleepTimer(minutes: nil) }

    // MARK: Retomar de onde parou

    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playback_state.json")
    }

    /// Serial: as gravações nunca se cruzam e o JSON da fila inteira não é codificado na thread principal.
    nonisolated private static let stateQueue = DispatchQueue(label: "dmusic.playback-state", qos: .utility)

    /// `blocking: true` (ao ir para segundo plano) espera a gravação terminar antes de retornar.
    func saveState(blocking: Bool = false) {
        guard !queue.isEmpty, queue.count <= 5000 else { return }
        let s = SavedPlayback(songs: queue, index: currentIndex, time: currentTime, source: playbackSource, originalSongs: originalQueue, shuffle: shuffle)
        let url = stateURL
        let write: @Sendable () -> Void = {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
        if blocking { Self.stateQueue.sync(execute: write) } else { Self.stateQueue.async(execute: write) }
    }

    /// Restaura fila, faixa e posição (pausado) ao abrir o app.
    func restoreState() {
        guard !restored else { return }
        restored = true
        guard queue.isEmpty, settings?.resumePlayback != false,
              let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(SavedPlayback.self, from: data),
              s.songs.indices.contains(s.index) else { return }
        playbackSource = s.source
        shuffle = s.shuffle ?? false
        originalQueue = s.originalSongs ?? s.songs
        queue = s.songs
        load(index: s.index, autoplay: false)
        if s.time > 1 { seek(to: s.time) }
    }

    func stop() {
        automixPrepareTask?.cancel()
        automixEngine.stop()
        gaplessPlayer.pause()
        gaplessPlayer.removeAllItems()
        usingEngineMode = false
        isAutomixing = false
        preparedMixHint = nil
        automixBadge = nil
        activeTransitionPlan = nil
        resetCoverStage()
        activeItem = nil
        preloadedIndex = nil
        itemIndex = [:]
        queue = []
        originalQueue = []
        shuffle = false
        playbackSource = nil
        isPlaying = false
        showNowPlaying = false
        deactivateSession()
        try? FileManager.default.removeItem(at: stateURL)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Navegação a partir do player

    private func appendToActiveTab<T: Hashable>(_ value: T, detailId: String) {
        showNowPlaying = false
        guard visibleDetailId != detailId else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            switch selectedTab {
            case .home: homePath.append(value)
            case .library: libraryPath.append(value)
            case .search: searchPath.append(value)
            }
        }
    }

    func navigateToSource() {
        guard let src = effectivePlaybackSource else { return }
        switch src {
        case .album(let album):
            appendToActiveTab(album, detailId: "album:\(album.id)")
        case .playlist(let playlist):
            appendToActiveTab(playlist, detailId: "playlist:\(playlist.id)")
        case .artist(let artist):
            appendToActiveTab(artist, detailId: "artist:\(artist.id)")
        case .library(let sectionRaw, _):
            showNowPlaying = false
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                selectedTab = .library
                libraryPath = NavigationPath()
                if let sec = LibrarySection(rawValue: sectionRaw) { requestedLibrarySection = sec }
            }
        case .search(let query):
            showNowPlaying = false
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                selectedTab = .search
                searchPath = NavigationPath()
                if !query.isEmpty { requestedSearchQuery = query }
            }
        case .djMix:
            break
        }
    }

    func navigateToSongAlbum(_ song: Song) {
        guard let client else {
            if let albumId = song.albumId, !albumId.isEmpty {
                let album = Album(id: albumId, name: song.album, title: song.album, artist: song.artist, artistId: song.artistId, coverArt: song.coverArt, year: song.year)
                appendToActiveTab(album, detailId: "album:\(album.id)")
            }
            return
        }
        showNowPlaying = false
        Task {
            let resolvedAlbum = await resolveAlbumForSong(song, client: client)
            if let resolvedAlbum {
                try? await Task.sleep(for: .milliseconds(180))
                guard visibleDetailId != "album:\(resolvedAlbum.id)" else { return }
                switch selectedTab {
                case .home: homePath.append(resolvedAlbum)
                case .library: libraryPath.append(resolvedAlbum)
                case .search: searchPath.append(resolvedAlbum)
                }
            }
        }
    }

    /// Resolve o álbum atual da faixa respeitando a pasta original (`song.path`) mesmo após migração de IDs no Navidrome.
    private func resolveAlbumForSong(_ song: Song, client: SubsonicClient) async -> Album? {
        if let aid = song.albumId, !aid.isEmpty, let liveAlbum = try? await client.album(id: aid) {
            return liveAlbum
        }
        if let freshSong = try? await client.song(id: song.id),
           let aid = freshSong.albumId, !aid.isEmpty,
           let liveAlbum = try? await client.album(id: aid) {
            return liveAlbum
        }
        let targetDir = song.path.map { ($0 as NSString).deletingLastPathComponent.lowercased() }
        if let sr = try? await client.search(song.title, artistCount: 0, albumCount: 15, songCount: 40),
           let candidates = sr.song, !candidates.isEmpty {
            let match = candidates.first(where: { cand in
                if let targetDir, !targetDir.isEmpty,
                   let cPath = cand.path,
                   (cPath as NSString).deletingLastPathComponent.lowercased() == targetDir {
                    return cand.title.caseInsensitiveCompare(song.title) == .orderedSame
                }
                return false
            }) ?? candidates.first(where: { cand in
                let sameTitle = cand.title.caseInsensitiveCompare(song.title) == .orderedSame
                let sameAlbum = (cand.album ?? "").caseInsensitiveCompare(song.album ?? "") == .orderedSame
                let sameSuffix = song.suffix == nil || cand.suffix == nil || cand.suffix == song.suffix
                return sameTitle && sameAlbum && sameSuffix
            }) ?? candidates.first

            if let match, let aid = match.albumId, !aid.isEmpty {
                if let liveAlbum = try? await client.album(id: aid) { return liveAlbum }
                return Album(id: aid, name: match.album, title: match.album, artist: match.artist, artistId: match.artistId, coverArt: match.coverArt, year: match.year)
            }
        }
        if let albumName = song.album, !albumName.isEmpty,
           let album = try? await client.search(albumName, artistCount: 0, albumCount: 10, songCount: 0).album?.first {
            return album
        }
        return nil
    }

    /// Pergunta qual artista abrir quando a faixa/álbum tem vários (painel de menu no estilo do app).
    func presentArtistPicker(_ entries: [ArtistParser.Entry]) {
        actionMenu = ActionMenuRequest(
            title: "Qual artista você quer acessar?",
            sections: [entries.map { entry in
                ActionMenuItem(title: entry.name, systemImage: "music.mic") { [weak self] in
                    self?.navigateToArtistEntry(entry)
                }
            }]
        )
    }

    func navigateToArtistEntry(_ entry: ArtistParser.Entry) {
        let artist = Artist(id: entry.id, name: entry.name, coverArt: entry.coverArt)
        appendToActiveTab(artist, detailId: "artist:\(entry.name.lowercased())")
    }

    func navigateToSongArtist(_ song: Song) {
        let entries = ArtistParser.artists(for: song)
        if entries.count > 1 {
            presentArtistPicker(entries)
            return
        }
        if let first = entries.first {
            navigateToArtistEntry(first)
            return
        }
        guard let client else { return }
        showNowPlaying = false
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            if let aid = song.albumId, let al = try? await client.album(id: aid) {
                let albEntries = ArtistParser.artists(for: al)
                if albEntries.count > 1 {
                    presentArtistPicker(albEntries)
                } else if let first = albEntries.first {
                    navigateToArtistEntry(first)
                }
            }
        }
    }

    // MARK: Lock screen

    private func configureRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlayPause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: ArtistParser.displayString(for: song),
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        else if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] { info[MPMediaItemPropertyArtwork] = existing }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = nil
        guard let cover = song.coverArt, let client else { return }
        Task {
            guard let img = await ImageCache.shared.image(id: cover, size: 600, client: client),
                  currentSong?.id == song.id else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            updateNowPlayingInfo(artwork: art)
        }
    }
}


/// Lembra como o usuário costuma montar o Mix DJ (focar, só gênero ou variar) para sugerir a opção mais usada.
enum MixFocusPreference {
    private static let key = "mix_focus_counts.v1"

    static func record(_ mode: SmartShuffler.MixFocus) {
        var counts = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        counts[mode.rawValue, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    /// Escolha mais frequente (nil enquanto não há histórico).
    static var preferred: SmartShuffler.MixFocus? {
        let counts = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return SmartShuffler.MixFocus(rawValue: best.key)
    }
}
