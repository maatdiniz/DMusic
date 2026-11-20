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
    var showNowPlaying = false
    var playbackSource: PlaybackSource?
    var selectedTab: AppTab = .home
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var requestedLibrarySection: LibrarySection?
    var requestedSearchQuery: String?
    var searchFocusTrigger: Int = 0
    var visibleDetailId: String?
    var artistChoices: [ArtistParser.Entry] = []
    var showArtistPicker = false

    /// Automix automático (sincroniza BPM com rampa na Faixa A antes da entrada,
    /// dispara Faixa B no downbeat via AVAudioEngine + Bass Swap e usa SmartShuffler).
    var automixEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixEnabled, forKey: "automix_enabled")
            if automixEnabled {
                logEvent(.engine, "Automix ativado", detail: "Fila mantida intacta. Modo Dual-Deck 48 kHz + EQ 5 bandas + Filtros ativo.")
                Task { await analysisStore?.syncFromServerIfStale(mixClient: mixClient) }
                onAutomixEnabledMidTrack()
            } else {
                logEvent(.engine, "Automix desativado", detail: "Fila mantida intacta. Retornando para reprodução Gapless pura.")
                automixPrepareTask?.cancel()
                automixEngine.clearPreparedIncoming()
                automixPhaseLabel = nil
                preparedMixHint = nil
                automixBadge = nil
                activeTransitionPlan = nil
                resetDJStage()
            }
            preloadNextInGapless()
        }
    }
    var automixPhaseLabel: String?
    var preparedMixHint: String?
    /// Badge curto, discreto e colorido exibido na tela de reprodução (ex.: "SINC ↑", "SINC ↓", "MIX • 3B", "MIX • EQ").
    var automixBadge: AutomixIndicatorBadge?
    /// Plano de transição armado para a faixa atual (usado para limitar o slider antes da transição e colorir a zona de rampa de BPM).
    var activeTransitionPlan: TransitionPlan?
    /// Estado visual das duas Jogs A & B na transição DJ (idle -> ramping -> mixing -> settling -> idle).
    var djStageMode: DJStageMode = .idle
    var djDeckACoverArt: String? = nil
    var djDeckBCoverArt: String? = nil
    var djDeckARate: Float = 1.0
    /// Progresso contínuo (0.0 a 1.0) da transição entre Jog A e Jog B.
    var transitionMixProgress: Double = 0
    /// BPM efetivo em tempo real durante rampa de sincronização, mixagem ou recuperação pós-transição (`nil` = exibir estático).
    var liveAnimatedBPM: Double? = nil
    /// Tendência do BPM ao vivo: `+1` subindo (âmbar), `-1` descendo (ciano), `0` cravado/sincronizado (verde).
    var liveBPMTrend: Int = 0
    /// BPM exibido sob a Jog A e sob a Jog B no palco dual-deck.
    var djDeckABPM: Double? = nil
    var djDeckBBPM: Double? = nil
    @ObservationIgnored private var djSettleSafetyTask: Task<Void, Never>?
    var isAutomixing: Bool { automixPhaseLabel != nil }

    private func resetDJStage(clearLiveBPM: Bool = true) {
        djSettleSafetyTask?.cancel()
        djSettleSafetyTask = nil
        djStageMode = .idle
        djDeckACoverArt = nil
        djDeckBCoverArt = nil
        djDeckARate = 1.0
        transitionMixProgress = 0.0
        djDeckABPM = nil
        djDeckBBPM = nil
        if clearLiveBPM {
            liveAnimatedBPM = nil
            liveBPMTrend = 0
        }
    }

    func finishDJStageSettling() {
        guard djStageMode == .settling else { return }
        resetDJStage(clearLiveBPM: false)
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
    var eventLogs: [AutomixEventLog] = []

    func logEvent(_ category: AutomixEventLog.Category, _ title: String, detail: String) {
        let entry = AutomixEventLog(timestamp: Date(), category: category, title: title, detail: detail)
        eventLogs.insert(entry, at: 0)
        if eventLogs.count > 250 {
            eventLogs.removeLast(eventLogs.count - 250)
        }
    }

    func clearLogs() {
        eventLogs.removeAll()
        lastSmartShuffleLog = nil
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
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var saveTick = 0
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
                self.saveTick += 1
                if self.saveTick % 40 == 0 { self.saveState() }
                if let d = self.gaplessPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.updateNowPlayingProgress()
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
            self.saveTick += 1
            if self.saveTick % 240 == 0 { self.saveState() }
            self.updateNowPlayingProgress()
        }

        automixEngine.onPhaseChanged = { [weak self] phase, plan in
            guard let self else { return }
            switch phase {
            case .idle, .playing:
                self.automixPhaseLabel = nil
                if self.djStageMode == .ramping {
                    self.resetDJStage()
                }
            case .ramping:
                let rateA = plan?.sync.targetRateA ?? 1.0
                if rateA > 1.003 {
                    self.automixPhaseLabel = "SINC ↑"
                    self.automixBadge = AutomixIndicatorBadge(text: "SINC", icon: "arrowtriangle.up.fill", kind: .syncUp)
                } else if rateA < 0.997 {
                    self.automixPhaseLabel = "SINC ↓"
                    self.automixBadge = AutomixIndicatorBadge(text: "SINC", icon: "arrowtriangle.down.fill", kind: .syncDown)
                } else {
                    self.automixPhaseLabel = "SINC"
                    self.automixBadge = AutomixIndicatorBadge(text: "SINC", icon: "equal", kind: .syncSteady)
                }
                self.djSettleSafetyTask?.cancel()
                let nextSongForStage = plan.flatMap { p in self.queue.first(where: { $0.id == p.trackB.id }) } ?? self.nextSongInQueue
                self.djDeckACoverArt = self.currentSong?.coverArt
                self.djDeckBCoverArt = nextSongForStage?.coverArt
                self.djDeckARate = rateA
                self.transitionMixProgress = 0.0
                if let p = plan {
                    self.djDeckABPM = p.trackA.bpm > 0 ? p.trackA.bpm : nil
                    let effectiveB = p.trackB.bpm * Double(p.sync.initialRateB ?? 1.0)
                    self.djDeckBBPM = effectiveB > 0 ? effectiveB : nil
                    if p.transitionType == "beatmatch", abs(rateA - 1.0) >= 0.003, p.trackA.bpm > 0 {
                        self.liveAnimatedBPM = p.trackA.bpm
                        self.liveBPMTrend = rateA > 1.0 ? 1 : -1
                    }
                }
                self.djStageMode = .ramping

                if let p = plan {
                    let pct = String(format: "%+.1f%%", (p.sync.targetRateA - 1.0) * 100.0)
                    self.logEvent(.sync, "Sincronizando BPM (\(pct))", detail: "Rampa iniciada em \(Self.formatMMSS(p.trackA.rampStartSec)) rumo a \(Self.formatMMSS(p.trackA.mixStartSec))")
                }
            case .mixing:
                let badge = Self.activeMixingBadge(for: plan)
                self.automixPhaseLabel = badge.text
                self.automixBadge = badge
                if let p = plan {
                    let vol = AutomixVolumeCurve(rawValue: p.mix.volumeCurve ?? "")?.title ?? "Sobrepor"
                    let eq = AutomixEQStyle(rawValue: p.mix.eqStyle ?? "")?.title ?? "Troca de Grave central"
                    let flt = AutomixFilterStyle(rawValue: p.mix.filterStyle ?? "")?.title ?? "Passa-alta"
                    self.logEvent(
                        .mix,
                        "Mixando (\(p.mix.bars ?? 8) compassos • \(badge.text))",
                        detail: "Saída \(Self.formatMMSS(p.trackA.mixStartSec)) (\(p.trackA.section ?? "inst")) → Entrada \(Self.formatMMSS(p.trackB.entrySec)) (\(p.trackB.section ?? "drop")) | Vol: \(vol) | EQ: \(eq) | Filtro: \(flt)"
                    )
                }
            }
        }

        automixEngine.onMixProgress = { [weak self] p in
            guard let self else { return }
            self.transitionMixProgress = Double(p)
        }

        automixEngine.onLiveBPMChanged = { [weak self] bpm, trend in
            guard let self else { return }
            self.liveAnimatedBPM = bpm
            self.liveBPMTrend = trend
            if self.djStageMode == .ramping, let bpm {
                self.djDeckABPM = bpm
                if trend == 0, let p = self.activeTransitionPlan,
                   p.transitionType == "beatmatch", abs(p.sync.targetRateA - 1.0) >= 0.003 {
                    self.automixPhaseLabel = "SINC"
                    self.automixBadge = AutomixIndicatorBadge(text: "SINC", icon: "equal", kind: .syncSteady)
                }
            } else if self.djStageMode == .mixing, let bpm {
                self.djDeckABPM = bpm
                self.djDeckBBPM = bpm
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

            self.djSettleSafetyTask?.cancel()
            if self.djStageMode != .ramping {
                self.djDeckACoverArt = previousSong?.coverArt
                self.djDeckBCoverArt = self.queue[idx].coverArt
                self.djDeckARate = self.activeTransitionPlan?.sync.targetRateA ?? 1.0
                if let p = self.activeTransitionPlan {
                    let rateA = p.sync.targetRateA
                    let effectiveA = p.trackA.bpm * Double(rateA)
                    let effectiveB = p.trackB.bpm * Double(p.sync.initialRateB ?? 1.0)
                    self.djDeckABPM = effectiveA > 0 ? effectiveA : nil
                    self.djDeckBBPM = effectiveB > 0 ? effectiveB : nil
                }
            }
            self.transitionMixProgress = 0.0
            self.djStageMode = .mixing

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
            self.logEvent(.mix, "Transição concluída → \(finishedSongTitle)", detail: "Deck B assumiu como Deck principal sem interrupção.")

            // Entra no estado de desaceleração suave da Jog B até chegar ao centro em tamanho 100% e alinhar em 0°!
            self.djDeckBCoverArt = self.currentSong?.coverArt
            self.transitionMixProgress = 1.0
            self.djStageMode = .settling
            self.djSettleSafetyTask?.cancel()
            self.djSettleSafetyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4.5))
                guard !Task.isCancelled else { return }
                self?.finishDJStageSettling()
            }

            self.automixPhaseLabel = nil
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
            self.resetDJStage()
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
        Task.detached(priority: .userInitiated) {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default)
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

    /// Álbuns ouvidos na sequência original mantêm Gapless puro; playlists, shuffle e listas usam Automix quando ativado.
    var shouldUseAutomix: Bool {
        guard automixEnabled, !sleepAtEndOfTrack else { return false }
        if !shuffle, case .album = effectivePlaybackSource {
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
        let gainDB: Float
        if let localURL = localFileURL(for: song.id),
           let measured = AutomixAudioEngine.measureLoudness(url: localURL) {
            gainDB = AutomixAudioEngine.computeGainDB(rmsDB: measured.rmsDB, peakDB: measured.peakDB, level: lvl)
        } else if let energy = analysisStore?.metadata(for: song.id)?.energy, energy > 0.05 {
            let estRMS = Float(max(energy * 0.38, 0.02))
            let estDB = 20.0 * log10(estRMS)
            gainDB = AutomixAudioEngine.computeGainDB(rmsDB: estDB, peakDB: -1.0, level: lvl)
        } else {
            gainDB = 0.0
        }
        // AVQueuePlayer só atenua (<= 1.0), então normalizamos com teto em 1.0 quando está em Gapless
        let linear = pow(10.0, gainDB / 20.0)
        gaplessPlayer.volume = min(max(linear, 0.35), 1.0)
    }

    /// Reativa o Modo DJ e reorganiza a fila inteira a partir da música que está tocando agora (sem interromper o áudio).
    func enableAutomixAndReorganizeFromCurrent() {
        shuffle = true
        if !automixEnabled { automixEnabled = true }
        guard let current = currentSong else { return }

        let priorityStart = currentIndex + 1
        let priorityEnd = min(queue.count, priorityStart + priorityCount)
        let prioritySongs = priorityStart < priorityEnd ? Array(queue[priorityStart..<priorityEnd]) : []
        let priorityIds = Set(prioritySongs.map(\.id))

        let poolSource = originalQueue.count >= queue.count ? originalQueue : queue
        var seen: Set<String> = [current.id]
        seen.formUnion(priorityIds)
        let remaining = poolSource.filter { seen.insert($0.id).inserted }

        if let store = analysisStore, !remaining.isEmpty {
            let anchor = prioritySongs.last ?? current
            let smartTail = SmartShuffler.smartShuffle(songs: [anchor] + remaining, metadata: store.items, startingWith: anchor).dropFirst()
            queue = [current] + prioritySongs + Array(smartTail)
            currentIndex = 0
            playbackSource = .djMix(seedTitle: current.title)
            recordSmartShuffleLog(songs: queue, reason: "Modo DJ reorganizado a partir de \(current.title)")
            queueChanged()
        } else if !remaining.isEmpty {
            queue = [current] + prioritySongs + remaining.shuffled()
            currentIndex = 0
            playbackSource = .djMix(seedTitle: current.title)
            queueChanged()
        }
        syncMetadataAndRefreshShuffleIfNeeded(source: playbackSource, originalCount: originalQueue.count)
    }

    // MARK: Playback control

    func play(songs: [Song], startAt index: Int = 0, source: PlaybackSource? = nil) {
        guard !songs.isEmpty, songs.indices.contains(index) else { return }
        playbackSource = source
        originalQueue = songs
        priorityCount = 0
        if shuffle {
            let chosen = songs[index]
            if automixEnabled, let store = analysisStore {
                queue = SmartShuffler.smartShuffle(songs: songs, metadata: store.items, startingWith: chosen)
                recordSmartShuffleLog(songs: queue, reason: "Play com Smart Shuffle")
            } else {
                var rest = songs
                rest.remove(at: index)
                queue = [chosen] + rest.shuffled()
            }
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
        playbackSource = source
        originalQueue = songs
        shuffle = shuffled
        priorityCount = 0
        if shuffled {
            if automixEnabled, let store = analysisStore {
                queue = SmartShuffler.smartShuffle(songs: songs, metadata: store.items)
                recordSmartShuffleLog(songs: queue, reason: "Play All com Smart Shuffle")
            } else {
                queue = songs.shuffled()
            }
        } else {
            queue = songs
        }
        load(index: 0)
        if automixEnabled {
            syncMetadataAndRefreshShuffleIfNeeded(source: source, originalCount: songs.count)
        }
    }

    /// Inicia imediatamente um Mix DJ (Automix + Smart Shuffle) a partir de `song` usando a lista local (`contextSongs`).
    func startDJMix(startingWith song: Song, in contextSongs: [Song], source: PlaybackSource?) {
        let pool = contextSongs.isEmpty ? [song] : contextSongs
        let idx = pool.firstIndex(where: { $0.id == song.id }) ?? 0
        shuffle = true
        if !automixEnabled { automixEnabled = true }
        play(songs: pool, startAt: idx, source: .djMix(seedTitle: song.title))
    }

    /// Inicia um Mix DJ (Automix + Smart Shuffle) a partir de `song` usando TODAS as músicas da biblioteca do servidor.
    func startFullLibraryDJMix(startingWith song: Song) async {
        guard let client else {
            startDJMix(startingWith: song, in: [song], source: .djMix(seedTitle: song.title))
            return
        }
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
        let idx = allSongs.firstIndex(where: { $0.id == song.id }) ?? 0
        shuffle = true
        if !automixEnabled { automixEnabled = true }
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

    private func recordSmartShuffleLog(songs: [Song], reason: String) {
        guard let store = analysisStore else { return }
        let report = SmartShuffler.buildShuffleReport(orderedSongs: songs, metadata: store.items)
        lastSmartShuffleLog = report
        logEvent(
            .shuffle,
            "\(reason) (\(report.totalTracks) faixas • média \(Int(report.averageScore.rounded())) pts)",
            detail: "IA allin1: \(report.aiAnalyzedCount) • Local: \(report.localAnalyzedCount) • Sem análise: \(report.unanalyzedCount)"
        )
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
        automixPhaseLabel = nil
        preparedMixHint = nil
        automixBadge = nil
        activeTransitionPlan = nil
        resetDJStage()

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
           let localURL = localFileURL(for: song.id),
           let audioFile = try? AVAudioFile(forReading: localURL),
           AutomixAudioEngine.canPlay(file: audioFile) {
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
                   let fileA = try? AVAudioFile(forReading: localA),
                   AutomixAudioEngine.canPlay(file: fileA) {
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
            if let localA = localFileURL(for: song.id),
               let fileA = try? AVAudioFile(forReading: localA),
               AutomixAudioEngine.canPlay(file: fileA) {
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

    private func reprepareIncomingIfNeeded() {
        guard shouldUseAutomix, usingEngineMode, !isAutomixing,
              let song = currentSong, let nextSong = nextSongInQueue else { return }
        automixPrepareTask?.cancel()
        automixPrepareTask = Task {
            await prepareIncomingAutomix(from: song, to: nextSong, protecting: [song.id, nextSong.id])
        }
    }

    private func applyUserAutomixOverrides(to rawPlan: TransitionPlan) -> TransitionPlan {
        var plan = rawPlan

        // Curva de Volume: por padrão ("auto") usa o que o servidor sugeriu ou "overlap" (Sobrepor)
        if automixVolumeCurve != .auto {
            plan.mix.volumeCurve = automixVolumeCurve.rawValue
        } else if (plan.mix.volumeCurve ?? "").isEmpty {
            plan.mix.volumeCurve = AutomixVolumeCurve.overlap.rawValue
        }

        // Estilo de EQ: por padrão ("auto") usa o sugerido pelo servidor ou "center_bass_swap" (Troca de Grave central)
        if automixEQStyle != .auto {
            plan.mix.eqStyle = automixEQStyle.rawValue
        } else if (plan.mix.eqStyle ?? "").isEmpty {
            plan.mix.eqStyle = AutomixEQStyle.centerBassSwap.rawValue
        }

        // Filtro Passa-Alta / Passa-Baixa: por padrão ("auto") usa o sugerido pelo servidor ou "hp_in_hp_out"
        if automixFilterStyle != .auto {
            plan.mix.filterStyle = automixFilterStyle.rawValue
        } else if (plan.mix.filterStyle ?? "").isEmpty {
            plan.mix.filterStyle = AutomixFilterStyle.hpInHpOut.rawValue
        }

        // Garante corte real de graves (-24 dB) para o EQ entrar no meio da transição mesmo em faixas com BPM distante
        if plan.mix.eqSwap.bassCutDb > -18.0 {
            plan.mix.eqSwap.bassCutDb = -24.0
        }

        // Reverb opcional
        if automixReverbEnabled {
            plan.mix.reverbTail = true
        }

        // Se o usuário fixou o número de compassos (2, 4, 8 ou 16) e o plano veio com número diferente (ex.: fallback local),
        // recalcula a janela proporcionalmente ao BPM da Faixa A
        if automixDurationChoice != .auto {
            let targetBars = automixDurationChoice.rawValue
            if plan.mix.bars != targetBars {
                let bpmA = max(plan.trackA.bpm, 65.0)
                let rateA = Double(max(plan.sync.targetRateA, 0.75))
                let barSecA = 4.0 * 60.0 / bpmA
                let spanA = barSecA * Double(targetBars)
                let durA = duration > 0 ? duration : max(plan.trackA.mixEndSec + 10.0, 120.0)
                let newEnd = min(durA - 0.25, plan.trackA.mixStartSec + spanA)
                let newStart = max(0.0, newEnd - spanA)
                plan.trackA.mixStartSec = newStart
                plan.trackA.mixEndSec = newEnd
                if plan.trackA.rampStartSec > newStart - 2.0 * barSecA {
                    plan.trackA.rampStartSec = max(durA * 0.38, newStart - 8.0 * barSecA)
                    if plan.trackA.rampStartSec > newStart {
                        plan.trackA.rampStartSec = max(0.0, newStart - 4.0 * barSecA)
                    }
                }
                if abs(plan.sync.targetRateA - 1.0) >= 0.003 {
                    let availLead = max(0.0, newStart - plan.trackA.rampStartSec)
                    plan.sync.rampDurationSec = min(max(plan.sync.rampDurationSec, min(availLead, 4.0 * barSecA)), availLead)
                }
                plan.mix.bars = targetBars
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

        guard let localB = localFileURL(for: songB.id),
              let fileB = try? AVAudioFile(forReading: localB),
              AutomixAudioEngine.canPlay(file: fileB) else {
            return
        }

        let barsOverride = automixDurationChoice == .auto ? nil : automixDurationChoice.rawValue

        // Busca TransitionPlan calculado pelo servidor allin1 (ou monta localmente se servidor estiver offline/ocupado)
        let rawPlan: TransitionPlan
        if let mixClient, let serverPlan = try? await mixClient.fetchTransition(from: songA.id, to: songB.id, barsOverride: barsOverride) {
            rawPlan = serverPlan
        } else {
            if let localA = localFileURL(for: songA.id) {
                _ = await analysisStore?.ensureAnalyzed(songId: songA.id, localURL: localA)
            }
            _ = await analysisStore?.ensureAnalyzed(songId: songB.id, localURL: localB)
            let durA = duration > 0 ? duration : Double(songA.duration ?? 180)
            rawPlan = SmartShuffler.buildLocalTransitionPlan(
                idA: songA.id,
                metaA: analysisStore?.metadata(for: songA.id),
                idB: songB.id,
                metaB: analysisStore?.metadata(for: songB.id),
                durationA: durA
            )
        }

        let plan = applyUserAutomixOverrides(to: rawPlan)

        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
        if let coverB = songB.coverArt {
            _ = await ImageCache.shared.image(id: coverB, size: 600, client: client)
        }
        guard !Task.isCancelled, currentSong?.id == songA.id, usingEngineMode, shouldUseAutomix else { return }
        automixEngine.prepareIncoming(fileB: fileB, songId: songB.id, plan: plan)
        activeTransitionPlan = plan

        let outStr = Self.formatMMSS(plan.trackA.mixStartSec)
        let inStr = Self.formatMMSS(plan.trackB.entrySec)
        let tag = (plan.source == "allin1") ? "MIX IA" : "MIX LOCAL"
        let barsTxt = plan.mix.bars.map { "\($0)c" } ?? ""
        let volShort = AutomixVolumeCurve(rawValue: plan.mix.volumeCurve ?? "")?.shortLabel ?? "SOBREPOR"
        let eqShort = AutomixEQStyle(rawValue: plan.mix.eqStyle ?? "")?.shortLabel ?? "EQ CENTRAL"
        let fltShort = AutomixFilterStyle(rawValue: plan.mix.filterStyle ?? "")?.shortLabel ?? ""
        let fxSummary = fltShort.isEmpty ? "\(volShort) • \(eqShort)" : "\(volShort) • \(eqShort) • \(fltShort)"
        preparedMixHint = "\(tag) (\(barsTxt)) • \(outStr)→\(inStr) • \(fxSummary)"

        // Badge armado discreto (mostra direção prevista do BPM quando em espera)
        if !isAutomixing {
            let r = plan.sync.targetRateA
            let icon = r > 1.003 ? "arrowtriangle.up.fill" : (r < 0.997 ? "arrowtriangle.down.fill" : "waveform")
            automixBadge = AutomixIndicatorBadge(text: "SINC \(outStr)", icon: icon, kind: .armed)
        }

        logEvent(
            plan.source == "allin1" ? .server : .engine,
            "Plano armado: \(songA.title) → \(songB.title)",
            detail: "\(tag) (\(plan.mix.bars ?? 8) comp.) | Saída \(outStr) [\(plan.trackA.section ?? "inst")] → Entrada \(inStr) [\(plan.trackB.section ?? "drop")] | Rate A: \(String(format: "%.3fx", plan.sync.targetRateA)) • Rate B: \(String(format: "%.3fx", plan.sync.initialRateB ?? 1.0)) | \(fxSummary)"
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
        let clampedSeconds: Double
        if shouldUseAutomix, let plan = activeTransitionPlan, plan.trackA.mixStartSec > 4.0 {
            clampedSeconds = min(max(0.0, seconds), max(0.0, plan.trackA.mixStartSec - 0.15))
        } else {
            clampedSeconds = max(0.0, seconds)
        }
        currentTime = clampedSeconds
        if usingEngineMode {
            preparedMixHint = nil
            activeTransitionPlan = nil
            automixPhaseLabel = nil
            automixBadge = nil
            resetDJStage()
            automixEngine.seek(to: clampedSeconds)
            if shouldUseAutomix, let cur = currentSong, let nextSong = nextSongInQueue {
                automixPrepareTask?.cancel()
                automixPrepareTask = Task {
                    await prepareIncomingAutomix(from: cur, to: nextSong, protecting: [cur.id, nextSong.id])
                }
            }
        } else {
            gaplessPlayer.seek(to: CMTime(seconds: clampedSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlayingProgress()
    }

    func scrubbing(_ active: Bool) { isScrubbing = active }

    func toggleShuffle() {
        shuffle.toggle()
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
                let smartTail = SmartShuffler.smartShuffle(songs: [anchor] + remaining, metadata: store.items, startingWith: anchor).dropFirst()
                queue = [current] + prioritySongs + Array(smartTail)
                recordSmartShuffleLog(songs: queue, reason: "Ativou Aleatório Inteligente")
                syncMetadataAndRefreshShuffleIfNeeded(source: playbackSource, originalCount: originalQueue.count)
            } else {
                queue = [current] + prioritySongs + remaining.shuffled()
            }
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

    /// Reorganiza as próximas faixas da fila aleatória com `SmartShuffler`.
    private func reorderUpcomingSmart(reason: String = "Reordenou fila para Automix") {
        guard shuffle, let store = analysisStore, let current = currentSong,
              currentIndex + 1 + priorityCount < queue.count else { return }
        let keepEnd = currentIndex + 1 + priorityCount
        let keptPrefix = Array(queue[0..<keepEnd])
        let tail = Array(queue[keepEnd..<queue.count])
        let anchor = keptPrefix.last ?? current
        let smartTail = SmartShuffler.smartShuffle(songs: [anchor] + tail, metadata: store.items, startingWith: anchor).dropFirst()
        queue = keptPrefix + Array(smartTail)
        recordSmartShuffleLog(songs: Array(queue[currentIndex..<queue.count]), reason: reason)
        queueChanged()
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
            if djStageMode == .ramping {
                resetDJStage()
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
        queueChanged()
    }

    func addToQueue(_ song: Song) {
        guard currentSong != nil else { play(songs: [song]); return }
        queue.append(song)
        if !originalQueue.isEmpty { originalQueue.append(song) }
        queueChanged()
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

    func saveState() {
        guard !queue.isEmpty, queue.count <= 5000 else { return }
        let s = SavedPlayback(songs: queue, index: currentIndex, time: currentTime, source: playbackSource, originalSongs: originalQueue, shuffle: shuffle)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
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
        automixPhaseLabel = nil
        preparedMixHint = nil
        automixBadge = nil
        activeTransitionPlan = nil
        resetDJStage()
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

    func navigateToArtistEntry(_ entry: ArtistParser.Entry) {
        showArtistPicker = false
        let artist = Artist(id: entry.id, name: entry.name, coverArt: entry.coverArt)
        appendToActiveTab(artist, detailId: "artist:\(entry.name.lowercased())")
    }

    func navigateToSongArtist(_ song: Song) {
        let entries = ArtistParser.artists(for: song)
        if entries.count > 1 {
            artistChoices = entries
            showArtistPicker = true
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
                    artistChoices = albEntries
                    showArtistPicker = true
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
