import Foundation
import AVFoundation
import Accelerate
import Darwin

nonisolated private struct NodeBox: @unchecked Sendable {
    weak var node: AVAudioPlayerNode?
}

/// Faz streaming em blocos PCM canônicos (48 kHz Float32 Stereo) via `AVAudioConverter`,
/// mantendo um grafo 100% estático no `AVAudioEngine` (evita qualquer `connect`/`disconnect` em tempo real).
nonisolated private final class DeckPCMStreamer: @unchecked Sendable {
    static let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private static let chunkSeconds: Double = 2.0

    private let queue = DispatchQueue(label: "com.dmusic.automix.streamer", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    private let fileURL: URL
    private let startAtSec: Double
    private let nodeBox: NodeBox

    // Acessados exclusivamente dentro de `queue`
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var srcScratch: AVAudioPCMBuffer?
    private var chunkOutFrames: AVAudioFrameCount = AVAudioFrameCount(48_000 * chunkSeconds)
    private var reachedInputEOF = false
    private var reachedOutputEOF = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    init(fileURL: URL, startAtSec: Double, node: AVAudioPlayerNode) {
        self.fileURL = fileURL
        self.startAtSec = startAtSec
        self.nodeBox = NodeBox(node: node)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.async { [weak self] in
            self?.pendingBuffers.removeAll()
        }
    }

    /// Prepara e agenda os primeiros blocos no `playerNode` (`syncBuffers` de forma síncrona e o restante em fila serial).
    func primeAndStartStreaming(syncBuffers: Int = 1, totalInitialBuffers: Int = 3) -> Bool {
        var primedOK = false
        queue.sync {
            guard !self.isCancelled else { return }
            guard self.prepareReaderOnQueue() else { return }
            let syncCount = max(1, syncBuffers)
            for i in 0..<syncCount {
                if self.isCancelled || self.reachedOutputEOF { break }
                if self.decodeAndScheduleOneOnQueue(), i == 0 {
                    primedOK = true
                }
            }
        }
        guard primedOK else { return false }

        let extraCount = max(0, totalInitialBuffers - max(1, syncBuffers))
        for _ in 0..<extraCount {
            queue.async { [weak self] in
                guard let self, !self.isCancelled, !self.reachedOutputEOF else { return }
                _ = self.decodeAndScheduleOneOnQueue()
            }
        }
        return true
    }

    /// Pré-decodifica os primeiros blocos em RAM sem agendar ainda no `playerNode`,
    /// permitindo inserir silêncio exato em frames antes do disparo para sincronia sample-accurate (< 1 ms).
    func primeToMemory(bufferCount: Int = 2) -> Bool {
        var primedOK = false
        queue.sync {
            guard !self.isCancelled else { return }
            guard self.prepareReaderOnQueue() else { return }
            self.pendingBuffers.removeAll()
            let count = max(1, bufferCount)
            for i in 0..<count {
                if self.isCancelled || self.reachedOutputEOF { break }
                if let buf = self.decodeOneBufferOnQueue() {
                    self.pendingBuffers.append(buf)
                    if i == 0 { primedOK = true }
                }
            }
        }
        return primedOK
    }

    /// Agenda o silêncio de pré-rolagem exato + os blocos já decodificados em RAM no `playerNode` e continua o streaming.
    func commitPendingAndStartStreaming(prerollSilenceFrames: Int) -> Bool {
        var committed = false
        queue.sync {
            guard !self.isCancelled, let targetNode = self.nodeBox.node, !self.pendingBuffers.isEmpty else { return }
            if prerollSilenceFrames > 0,
               let silenceBuf = AVAudioPCMBuffer(pcmFormat: Self.renderFormat, frameCapacity: AVAudioFrameCount(prerollSilenceFrames)) {
                silenceBuf.frameLength = AVAudioFrameCount(prerollSilenceFrames)
                // AVAudioPCMBuffer recém-alocado pode conter lixo; zera explicitamente todos os canais
                if let ch = silenceBuf.floatChannelData {
                    let bytes = prerollSilenceFrames * MemoryLayout<Float>.size
                    for c in 0..<Int(Self.renderFormat.channelCount) {
                        memset(ch[c], 0, bytes)
                    }
                }
                targetNode.scheduleBuffer(silenceBuf, completionHandler: nil)
            }
            for buf in self.pendingBuffers {
                targetNode.scheduleBuffer(buf, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.isCancelled, !self.reachedOutputEOF else { return }
                        _ = self.decodeAndScheduleOneOnQueue()
                    }
                }
            }
            self.pendingBuffers.removeAll()
            committed = true
        }
        if committed {
            queue.async { [weak self] in
                guard let self, !self.isCancelled, !self.reachedOutputEOF else { return }
                _ = self.decodeAndScheduleOneOnQueue()
            }
        }
        return committed
    }

    private func prepareReaderOnQueue() -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let inFormat = audioFile.processingFormat
            guard audioFile.length > 0,
                  let conv = AVAudioConverter(from: inFormat, to: Self.renderFormat) else {
                return false
            }
            conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            if inFormat.channelCount == 1 {
                conv.channelMap = [0, 0]
            }

            let sr = max(inFormat.sampleRate, 1)
            let targetFrame = AVAudioFramePosition(max(0.0, startAtSec) * sr)
            audioFile.framePosition = min(max(0, targetFrame), max(0, audioFile.length - 1))

            let scratchCap = AVAudioFrameCount(max(16_384, Int(ceil(sr * (Self.chunkSeconds + 0.25)))))
            guard let scratch = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: scratchCap) else {
                return false
            }

            self.file = audioFile
            self.converter = conv
            self.srcScratch = scratch
            self.chunkOutFrames = AVAudioFrameCount(Self.renderFormat.sampleRate * Self.chunkSeconds)
            self.reachedInputEOF = false
            self.reachedOutputEOF = false
            return true
        } catch {
            return false
        }
    }

    private func decodeOneBufferOnQueue() -> AVAudioPCMBuffer? {
        guard !isCancelled, !reachedOutputEOF,
              let file, let converter, let srcScratch,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: Self.renderFormat, frameCapacity: chunkOutFrames) else {
            return nil
        }

        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { requestedPackets, outStatus in
            if self.isCancelled || self.reachedInputEOF {
                outStatus.pointee = .endOfStream
                return nil
            }
            let framesToRead = min(max(requestedPackets, 1), srcScratch.frameCapacity)
            do {
                try file.read(into: srcScratch, frameCount: framesToRead)
            } catch {
                self.reachedInputEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if srcScratch.frameLength == 0 {
                self.reachedInputEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return srcScratch
        }

        if status == .error || outBuffer.frameLength == 0 {
            reachedOutputEOF = true
            return nil
        }
        if status == .endOfStream {
            reachedOutputEOF = true
        }
        guard !isCancelled else { return nil }
        return outBuffer
    }

    private func decodeAndScheduleOneOnQueue() -> Bool {
        guard let targetNode = nodeBox.node,
              let outBuffer = decodeOneBufferOnQueue() else {
            return false
        }

        targetNode.scheduleBuffer(outBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.isCancelled, !self.reachedOutputEOF else { return }
                _ = self.decodeAndScheduleOneOnQueue()
            }
        }
        return true
    }
}

/// Motor Dual-Deck Profissional de DJ em `AVAudioEngine` (Grafo 100% estático a 48 kHz Stereo):
///
///   Deck A: AVAudioPlayerNode -> AVAudioUnitTimePitch -> AVAudioUnitEQ (5 bandas: Low/Mid/High + HPF + LPF) -> AVAudioUnitReverb ─┐
///                                                                                                                                   ├─► mainMixerNode
///   Deck B: AVAudioPlayerNode -> AVAudioUnitTimePitch -> AVAudioUnitEQ (5 bandas: Low/Mid/High + HPF + LPF) -> AVAudioUnitReverb ─┘
///
/// Suporta todos os modos de Volume (Sobrepor, Corte na entrada/saída, Corte central, 1 compasso, Fade cruzado),
/// todos os estilos de EQ (Troca de grave central/início/fim, Transição de 3 bandas, Corte rápido/longo, Fade out de graves),
/// todos os Filtros DJ (Passa-baixa / Passa-alta na entrada e/ou saída, Passa-alta parcial, Wash-out final com Reverb)
/// e Dual-Deck Tempo Bridge (`targetRateA` + `initialRateB` deslizando de volta para `1.0x`).
@MainActor
final class AutomixAudioEngine {
    enum Phase: String {
        case idle
        case playing
        case ramping
        case mixing
    }

    private final class DeckChannel {
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        /// 5 bandas por Deck:
        /// - Band 0: Low Shelf (185 Hz) -> Bass Swap / Corte de Graves
        /// - Band 1: Parametric Mid (1050 Hz, BW 1.6 oct) -> Transição de 3 Bandas (Médios/Vocais)
        /// - Band 2: High Shelf (4200 Hz) -> Transição de 3 Bandas (Agudos/Brilho)
        /// - Band 3: High-Pass Filter (20 Hz a 3600 Hz) -> Filtro Passa-Alta DJ (Entrada/Saída)
        /// - Band 4: Low-Pass Filter (240 Hz a 20000 Hz) -> Filtro Passa-Baixa DJ (Entrada/Saída)
        let eq = AVAudioUnitEQ(numberOfBands: 5)
        let reverb = AVAudioUnitReverb()

        var file: AVAudioFile?
        var songId: String?
        var nominalBPM: Double = 0
        var loudnessRMSDB: Float? = nil
        var loudnessPeakDB: Float? = nil
        var streamer: DeckPCMStreamer?
        var segmentStartSec: Double = 0
        var prerollSilenceSec: Double = 0
        var fileDuration: Double = 0
        var isPaused = false

        init() {
            let b = eq.bands
            if b.count >= 5 {
                // Band 0: Graves (Low Shelf 185 Hz)
                b[0].filterType = .lowShelf
                b[0].frequency = 185.0
                b[0].gain = 0.0
                b[0].bypass = false

                // Band 1: Médios (Parametric 1050 Hz)
                b[1].filterType = .parametric
                b[1].frequency = 1050.0
                b[1].bandwidth = 1.6
                b[1].gain = 0.0
                b[1].bypass = false

                // Band 2: Agudos (High Shelf 4200 Hz)
                b[2].filterType = .highShelf
                b[2].frequency = 4200.0
                b[2].gain = 0.0
                b[2].bypass = false

                // Band 3: Filtro Passa-Alta (High-Pass)
                b[3].filterType = .highPass
                b[3].frequency = 20.0
                b[3].bypass = true

                // Band 4: Filtro Passa-Baixa (Low-Pass)
                b[4].filterType = .lowPass
                b[4].frequency = 20_000.0
                b[4].bypass = true
            }
            reverb.loadFactoryPreset(.largeHall2)
            reverb.wetDryMix = 0.0
        }

        func resetDSPToNeutral() {
            let b = eq.bands
            if b.count >= 5 {
                b[0].gain = 0.0
                b[1].gain = 0.0
                b[2].gain = 0.0
                b[3].frequency = 20.0
                b[3].bypass = true
                b[4].frequency = 20_000.0
                b[4].bypass = true
            }
            reverb.wetDryMix = 0.0
        }
    }

    private static let renderFormat = DeckPCMStreamer.renderFormat

    private let engine = AVAudioEngine()
    private let decks = [DeckChannel(), DeckChannel()]
    private var activeIndex = 0
    private var isSetup = false
    private var monitorTimer: Timer?

    // Estado da transição preparada para o par atual -> próximo
    private var transitionPlan: TransitionPlan?
    private var incomingSongId: String?
    private var hasStartedIncoming = false
    private var hasTriggeredPlayAtFuture = false
    private var lastReportedPhase: Phase = .idle
    private var lastKnownTime: Double = 0
    private var incomingLastKnownTime: Double = 0
    private var configObserver: NSObjectProtocol?
    private(set) var isPlaying = false
    var isEngineRunning: Bool { engine.isRunning }

    var volumeCompensation: VolumeCompensationLevel = .off {
        didSet { reapplyLoudnessGain() }
    }
    private var loudnessCache: [String: (rmsDB: Float, peakDB: Float)] = [:]

    /// Mede RMS e Peak (dBFS) em 10 fatias do miolo do arquivo (~10ms) para compensação de volume sem clipping.
    static func measureLoudness(url: URL) -> (rmsDB: Float, peakDB: Float)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        guard sr > 0, totalFrames > 4096 else { return nil }

        let sliceFrames = AVAudioFrameCount(min(Int64(sr * 0.18), totalFrames / 4))
        guard sliceFrames >= 512,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sliceFrames) else { return nil }

        var sumSquares: Double = 0
        var sampleCount: Int = 0
        var maxPeak: Float = 0.0001
        let slices = 10

        for i in 0..<slices {
            let frac = 0.14 + (0.72 * Double(i) / Double(max(slices - 1, 1)))
            let pos = min(max(0, Int64(Double(totalFrames) * frac)), max(0, totalFrames - Int64(sliceFrames)))
            file.framePosition = pos
            do {
                buf.frameLength = 0
                try file.read(into: buf, frameCount: sliceFrames)
            } catch {
                continue
            }
            let n = Int(buf.frameLength)
            guard n > 0, let channels = buf.floatChannelData else { continue }
            let chCount = Int(buf.format.channelCount)
            for ch in 0..<chCount {
                var rms: Float = 0
                var pk: Float = 0
                vDSP_rmsqv(channels[ch], 1, &rms, vDSP_Length(n))
                vDSP_maxmgv(channels[ch], 1, &pk, vDSP_Length(n))
                sumSquares += Double(rms * rms) * Double(n)
                sampleCount += n
                if pk > maxPeak { maxPeak = pk }
            }
        }
        guard sampleCount > 0 else { return nil }
        let rms = max(Float(sqrt(sumSquares / Double(sampleCount))), 0.0001)
        let rmsDB = 20.0 * log10(rms)
        let peakDB = 20.0 * log10(maxPeak)
        return (rmsDB, peakDB)
    }

    static func computeGainDB(rmsDB: Float, peakDB: Float, level: VolumeCompensationLevel) -> Float {
        guard level != .off else { return 0.0 }
        let desired = level.targetDBFS - rmsDB
        let clamped = min(max(desired, level.maxCutDB), level.maxBoostDB)
        // Proteção contra clipping: nunca empurra o pico acima de -0.5 dBFS
        let peakSafe = min(clamped, -0.5 - peakDB)
        return max(peakSafe, level.maxCutDB)
    }

    private func applyLoudness(to deck: DeckChannel, fileURL: URL?, songId: String?) {
        guard let songId else {
            deck.loudnessRMSDB = nil
            deck.loudnessPeakDB = nil
            deck.eq.globalGain = 0.0
            return
        }
        if let cached = loudnessCache[songId] {
            deck.loudnessRMSDB = cached.rmsDB
            deck.loudnessPeakDB = cached.peakDB
        } else if let url = fileURL, let measured = Self.measureLoudness(url: url) {
            loudnessCache[songId] = measured
            deck.loudnessRMSDB = measured.rmsDB
            deck.loudnessPeakDB = measured.peakDB
        } else {
            deck.loudnessRMSDB = nil
            deck.loudnessPeakDB = nil
        }

        if let rms = deck.loudnessRMSDB, let pk = deck.loudnessPeakDB {
            deck.eq.globalGain = Self.computeGainDB(rmsDB: rms, peakDB: pk, level: volumeCompensation)
        } else {
            deck.eq.globalGain = 0.0
        }
    }

    private func reapplyLoudnessGain() {
        for d in decks {
            if let rms = d.loudnessRMSDB, let pk = d.loudnessPeakDB {
                d.eq.globalGain = Self.computeGainDB(rmsDB: rms, peakDB: pk, level: volumeCompensation)
            } else {
                d.eq.globalGain = 0.0
            }
        }
    }

    // Recuperação suave de BPM pós-transição quando a Faixa B entrou com `initialRateB != 1.0`
    private var postTransitionRateStart: Float = 1.0
    private var postTransitionRecoverStartTime: Double = 0
    private var postTransitionRecoverDuration: Double = 0
    private var lastEmittedLiveBPMTenths: Int? = nil
    private var lastEmittedLiveBPMTrend: Int = 0

    // Callbacks para o AudioPlayerManager atualizar UI, capa, Lock Screen e scrobble
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onPhaseChanged: ((Phase, TransitionPlan?) -> Void)?
    var onMixProgress: ((Float) -> Void)?
    /// `(liveBPM, trend)` onde `trend`: `+1` subindo, `-1` descendo, `0` sincronizado/estável. `liveBPM == nil` retorna ao estático.
    var onLiveBPMChanged: ((Double?, Int) -> Void)?
    /// Disparado no exato momento em que a transição começa (`mixStartSec`), quando a Música B entra na mixagem.
    var onTransitionStarted: ((String) -> Void)?
    var onTransitionCompleted: ((String) -> Void)?
    var onTrackEndedWithoutNext: (() -> Void)?

    private var activeDeck: DeckChannel { decks[activeIndex] }
    private var incomingDeck: DeckChannel { decks[activeIndex == 0 ? 1 : 0] }
    /// Quando a transição está ativa (`hasStartedIncoming`), a UI já exibe o tempo/duração da Música B que entrou!
    private var uiReportingDeck: DeckChannel { hasStartedIncoming ? incomingDeck : activeDeck }

    static func canPlay(file: AVAudioFile) -> Bool {
        file.length > 0 && AVAudioConverter(from: file.processingFormat, to: renderFormat) != nil
    }

    init() {
        setupEngineIfNeeded()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isPlaying, activeDeck.file != nil else { return }
        stopMonitoring()

        // Captura o tempo real ANTES de qualquer reset — nunca sobrescreve com 0 se o hardware já parou
        let resumeTime: Double
        if hasStartedIncoming, incomingDeck.file != nil {
            resumeTime = max(incomingLastKnownTime, validRenderTime(for: incomingDeck) ?? incomingDeck.segmentStartSec)
        } else {
            resumeTime = max(lastKnownTime, validRenderTime(for: activeDeck) ?? activeDeck.segmentStartSec)
        }

        let savedPlan = hasStartedIncoming ? nil : transitionPlan
        let savedFileB = hasStartedIncoming ? nil : incomingDeck.file
        let savedSongIdB = hasStartedIncoming ? nil : incomingSongId

        AVAudioSession.sharedInstance().activate(options: []) { _, _ in }
        seek(to: resumeTime)

        if let savedPlan, let savedFileB, let savedSongIdB {
            prepareIncoming(fileB: savedFileB, songId: savedSongIdB, plan: savedPlan)
        }
    }

    func recoverAfterRouteChange() {
        guard isPlaying, activeDeck.file != nil, !engine.isRunning else { return }
        handleConfigurationChange()
    }

    private func setupEngineIfNeeded() {
        guard !isSetup else { return }
        isSetup = true

        // Grafo 100% estático em 48 kHz Stereo: nunca desconecta ou reconecta nós após o setup
        for deck in decks {
            engine.attach(deck.playerNode)
            engine.attach(deck.timePitch)
            engine.attach(deck.eq)
            engine.attach(deck.reverb)
            engine.connect(deck.playerNode, to: deck.timePitch, format: Self.renderFormat)
            engine.connect(deck.timePitch, to: deck.eq, format: Self.renderFormat)
            engine.connect(deck.eq, to: deck.reverb, format: Self.renderFormat)
            engine.connect(deck.reverb, to: engine.mainMixerNode, format: Self.renderFormat)
        }
        engine.prepare()
    }

    private func ensureRunning() {
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    private func resetDeckNode(_ deck: DeckChannel) {
        deck.streamer?.cancel()
        deck.streamer = nil
        deck.playerNode.stop()
        deck.playerNode.reset()
        deck.resetDSPToNeutral()
        deck.prerollSilenceSec = 0
        deck.isPaused = false
    }

    // MARK: - Leitura do tempo interno exato (sample-accurate mesmo com TimePitch ativo)

    func currentTrackTime() -> Double {
        currentTime(for: activeDeck)
    }

    private func validRenderTime(for deck: DeckChannel) -> Double? {
        guard engine.isRunning, !deck.isPaused, deck.playerNode.isPlaying,
              let nodeTime = deck.playerNode.lastRenderTime,
              let playerTime = deck.playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime > 0 else {
            return nil
        }
        let pRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : Self.renderFormat.sampleRate
        let elapsed = max(0, Double(playerTime.sampleTime) / pRate - deck.prerollSilenceSec)
        return min(deck.segmentStartSec + elapsed, deck.fileDuration)
    }

    /// Detecta o ataque real da batida/bumbo (kick onset) no PCM decodificado pelo próprio `AVAudioFile`
    /// numa janela curta de ±35 ms ao redor do timestamp planejado. Elimina desvio de priming MP3/AAC
    /// sem jamais pular para uma caixa/contratempo distante. Retorna `targetSec` inalterado sem percussão clara.
    private static func snapToNearestBeatOnset(url: URL, targetSec: Double, maxShiftSec: Double = 0.035) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return targetSec }
        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        guard sr >= 8_000, totalFrames > 4_096 else { return targetSec }
        let dur = Double(totalFrames) / sr

        let searchRadius = maxShiftSec + 0.015
        let winStart = max(0.0, targetSec - searchRadius)
        let winEnd = min(dur - 0.02, targetSec + searchRadius)
        guard winEnd - winStart >= 0.06 else { return targetSec }

        let startFrame = AVAudioFramePosition(winStart * sr)
        let frameCount = AVAudioFrameCount(min(Double(totalFrames - startFrame), (winEnd - winStart) * sr))
        guard frameCount >= 512,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return targetSec
        }

        file.framePosition = startFrame
        do {
            try file.read(into: buf, frameCount: frameCount)
        } catch {
            return targetSec
        }

        let n = Int(buf.frameLength)
        guard n >= 512, let chData = buf.floatChannelData else { return targetSec }
        let chCount = Int(buf.format.channelCount)

        // Mix para mono Float32
        var mono = [Float](repeating: 0, count: n)
        if chCount == 1 {
            memcpy(&mono, chData[0], n * MemoryLayout<Float>.size)
        } else {
            var scale: Float = 1.0 / Float(chCount)
            for c in 0..<chCount {
                vDSP_vsma(chData[c], 1, &scale, mono, 1, &mono, 1, vDSP_Length(n))
            }
        }

        // Filtro passa-baixa de 1 polo (~160 Hz) para isolar exclusivamente o ataque do bumbo (kick)
        let alpha = Float(1.0 - exp(-2.0 * Double.pi * 160.0 / sr))
        var low = [Float](repeating: 0, count: n)
        var y: Float = 0
        for i in 0..<n {
            y += alpha * (mono[i] - y)
            low[i] = y
        }

        // Energia focada no bumbo (85% sub-grave/kick + 15% banda larga) em quadros de 5 ms com salto de 2.5 ms
        let hop = max(1, Int(round(sr * 0.0025)))
        let win = max(hop * 2, Int(round(sr * 0.005)))
        let numFrames = (n - win) / hop
        guard numFrames >= 8 else { return targetSec }

        var energies = [Float](repeating: 0, count: numFrames)
        for f in 0..<numFrames {
            let offset = f * hop
            var rmsLow: Float = 0
            var rmsFull: Float = 0
            low.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rmsLow, vDSP_Length(win))
            }
            mono.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rmsFull, vDSP_Length(win))
            }
            energies[f] = 0.85 * rmsLow + 0.15 * rmsFull
        }

        // Fluxo de onset positivo (subida súbita de energia = ataque da batida)
        var flux = [Float](repeating: 0, count: numFrames)
        for f in 1..<numFrames {
            flux[f] = max(0, energies[f] - energies[f - 1])
        }

        // Mediana do fluxo para garantir que só faz snap em transientes reais (ignora intros/outros ambientes)
        let sortedFlux = flux.sorted()
        let medianFlux = max(sortedFlux[sortedFlux.count / 2], 1e-6)

        // Ponderação suave favorecendo onsets próximos ao timestamp planejado
        var bestIdx = -1
        var bestScore: Float = 0
        var bestRawFlux: Float = 0
        for f in 1..<numFrames {
            let frameSec = winStart + Double(f * hop) / sr
            let dist = abs(frameSec - targetSec)
            guard dist <= maxShiftSec else { continue }
            let weight = Float(1.0 - 0.30 * (dist / maxShiftSec))
            let score = flux[f] * weight
            if score > bestScore {
                bestScore = score
                bestRawFlux = flux[f]
                bestIdx = f
            }
        }

        guard bestIdx >= 1, bestRawFlux >= medianFlux * 2.8, bestRawFlux >= 0.002 else {
            return targetSec
        }

        // Recua 1 salto (~2.5 ms) para o início exato da rampa de ataque do bumbo
        let snappedSec = winStart + Double(max(0, bestIdx - 1) * hop) / sr
        return min(max(0.0, snappedSec), dur - 0.05)
    }

    private func currentTime(for deck: DeckChannel) -> Double {
        if let valid = validRenderTime(for: deck) {
            return valid
        }
        if deck === activeDeck {
            return max(lastKnownTime, deck.segmentStartSec)
        }
        if deck === incomingDeck, hasStartedIncoming {
            return max(incomingLastKnownTime, deck.segmentStartSec)
        }
        return deck.segmentStartSec
    }

    // MARK: - Reprodução Principal & Preparo do Deck B

    func startPlaying(file: AVAudioFile, songId: String, startAtSec: Double = 0, autoplay: Bool = true) {
        stopMonitoring()
        postTransitionRecoverDuration = 0
        resetTransitionState()
        reportLiveBPM(nil, trend: 0)

        for d in decks {
            resetDeckNode(d)
            d.file = nil
            d.songId = nil
            d.nominalBPM = 0
        }

        let deck = activeDeck
        let sr = file.processingFormat.sampleRate
        let totalDur = Double(file.length) / max(sr, 1)
        let clampedSec = min(max(startAtSec, 0), max(totalDur - 0.5, 0))

        deck.file = file
        deck.songId = songId
        deck.fileDuration = totalDur
        deck.segmentStartSec = clampedSec
        lastKnownTime = clampedSec
        deck.timePitch.rate = 1.0
        deck.timePitch.pitch = 0.0
        deck.resetDSPToNeutral()
        applyLoudness(to: deck, fileURL: file.url, songId: songId)
        deck.playerNode.volume = 1.0

        let streamer = DeckPCMStreamer(fileURL: file.url, startAtSec: clampedSec, node: deck.playerNode)
        deck.streamer = streamer
        guard streamer.primeAndStartStreaming(syncBuffers: 1, totalInitialBuffers: 3) else {
            deck.streamer = nil
            deck.file = nil
            deck.songId = nil
            isPlaying = false
            return
        }

        if autoplay {
            ensureRunning()
            deck.playerNode.play()
            deck.isPaused = false
            isPlaying = true
            startMonitoring()
        } else {
            isPlaying = false
        }

        reportPhase(.playing, plan: nil)
        onTimeUpdate?(clampedSec, totalDur)
    }

    /// Agenda o Deck B já posicionado no `entry_sec` (downbeat inicial) pronto para sobreposição + EQ + Filtro DJ.
    func prepareIncoming(fileB: AVAudioFile, songId: String, plan: TransitionPlan) {
        guard !hasStartedIncoming, !hasTriggeredPlayAtFuture else { return }
        guard Self.canPlay(file: fileB) else {
            clearPreparedIncoming()
            return
        }

        var effectivePlan = plan
        let now = currentTime(for: activeDeck)
        let durA = activeDeck.fileDuration
        if durA > 0, now >= plan.trackA.mixStartSec - 0.5 {
            let remaining = durA - now
            guard remaining >= 4.0 else {
                clearPreparedIncoming()
                return
            }
            let fadeStart = max(now + 0.5, durA - min(7.0, remaining * 0.65))
            let fadeEnd = max(fadeStart + 2.5, durA - 0.35)
            effectivePlan.trackA.rampStartSec = fadeStart
            effectivePlan.trackA.mixStartSec = fadeStart
            effectivePlan.trackA.mixEndSec = fadeEnd
            effectivePlan.sync.targetRateA = 1.0
            effectivePlan.sync.initialRateB = 1.0
            effectivePlan.sync.rampDurationSec = 0.0
            effectivePlan.mix.durationSec = fadeEnd - fadeStart
            activeDeck.timePitch.rate = 1.0
            activeDeck.resetDSPToNeutral()
        }

        let incoming = incomingDeck
        resetDeckNode(incoming)

        let sr = fileB.processingFormat.sampleRate
        let totalDur = Double(fileB.length) / max(sr, 1)

        // 1. Micro-alinhamento de batida no PCM real (elimina desvio de priming MP3/AAC e jitter de downbeat)
        if effectivePlan.transitionType == "beatmatch" {
            let origMixStart = effectivePlan.trackA.mixStartSec
            let origEntryB = effectivePlan.trackB.entrySec

            if let urlA = activeDeck.file?.url, durA > 0, now < origMixStart - 0.5 {
                let snappedA = Self.snapToNearestBeatOnset(url: urlA, targetSec: origMixStart)
                let deltaA = snappedA - origMixStart
                if abs(deltaA) >= 0.002 && abs(deltaA) <= 0.085 {
                    effectivePlan.trackA.mixStartSec = snappedA
                    effectivePlan.trackA.mixEndSec = min(durA - 0.15, effectivePlan.trackA.mixEndSec + deltaA)
                }
            }

            let snappedB = Self.snapToNearestBeatOnset(url: fileB.url, targetSec: origEntryB)
            let deltaB = snappedB - origEntryB
            if abs(deltaB) >= 0.002 && abs(deltaB) <= 0.085 {
                effectivePlan.trackB.entrySec = snappedB
            }

            // 2. Alinhamento rápido de BPM: rampa curta de 2–4 compassos + 1 compasso travado antes da entrada
            //    para que o TimePitch esteja 100% estável em fase antes do disparo do Deck B.
            let rateDelta = Double(abs(effectivePlan.sync.targetRateA - 1.0))
            if rateDelta >= 0.003 {
                let barSec = 4.0 * 60.0 / max(effectivePlan.trackA.bpm, 60.0)
                let rampBars: Double = rateDelta < 0.020 ? 2.0 : (rateDelta < 0.045 ? 3.0 : 4.0)
                let holdBars: Double = 1.0
                let fastRampSec = min(max(rampBars * barSec, 2.5), 9.0)
                let fastHoldSec = min(max(holdBars * barSec, 1.4), 2.5)
                let fastLeadSec = fastRampSec + fastHoldSec
                let desiredRampStart = max(0.0, effectivePlan.trackA.mixStartSec - fastLeadSec)
                if desiredRampStart > effectivePlan.trackA.rampStartSec {
                    effectivePlan.trackA.rampStartSec = desiredRampStart
                    effectivePlan.sync.rampDurationSec = fastRampSec
                }
            }

            let dAMs = Int(((effectivePlan.trackA.mixStartSec - origMixStart) * 1000.0).rounded())
            let dBMs = Int(((effectivePlan.trackB.entrySec - origEntryB) * 1000.0).rounded())
            print(String(format: "[SYNC-LOCK] BeatSnap A:%+dms (%.3fs) | B:%+dms (%.3fs) | Ramp:%.1fs→%.1fs | RateA:%.3fx RateB:%.3fx",
                         dAMs, effectivePlan.trackA.mixStartSec,
                         dBMs, effectivePlan.trackB.entrySec,
                         effectivePlan.trackA.rampStartSec, effectivePlan.trackA.mixStartSec,
                         effectivePlan.sync.targetRateA, effectivePlan.sync.initialRateB ?? 1.0))
        }

        let clampedEntry = min(max(effectivePlan.trackB.entrySec, 0), max(totalDur - 4.0, 0))

        activeDeck.nominalBPM = effectivePlan.trackA.bpm
        incoming.file = fileB
        incoming.songId = songId
        incoming.nominalBPM = effectivePlan.trackB.bpm
        incoming.fileDuration = totalDur
        incoming.segmentStartSec = clampedEntry
        incoming.prerollSilenceSec = 0
        incoming.timePitch.rate = effectivePlan.sync.initialRateB ?? 1.0
        incoming.timePitch.pitch = 0.0
        incoming.playerNode.volume = 0.0
        incoming.resetDSPToNeutral()
        applyLoudness(to: incoming, fileURL: fileB.url, songId: songId)

        // Pré-posiciona EQ/Filtros do Deck B no instante p = 0.0 para entrada sem estalo
        applyTransitionDSP(progress: 0.0, plan: effectivePlan, outgoing: activeDeck, incoming: incoming, primeOnlyIncoming: true)

        let streamer = DeckPCMStreamer(fileURL: fileB.url, startAtSec: clampedEntry, node: incoming.playerNode)
        incoming.streamer = streamer
        guard streamer.primeToMemory(bufferCount: 2) else {
            resetDeckNode(incoming)
            incoming.file = nil
            incoming.songId = nil
            incoming.nominalBPM = 0
            resetTransitionState()
            return
        }

        transitionPlan = effectivePlan
        incomingSongId = songId
        if isPlaying {
            ensureRunning()
        }
    }

    func clearPreparedIncoming() {
        guard !hasStartedIncoming else { return }
        activeDeck.timePitch.rate = 1.0
        resetDeckNode(incomingDeck)
        incomingDeck.file = nil
        incomingDeck.songId = nil
        incomingDeck.nominalBPM = 0
        resetTransitionState()
        if postTransitionRecoverDuration <= 0.05 {
            reportLiveBPM(nil, trend: 0)
        }
    }

    func seek(to seconds: Double) {
        // Se já estávamos no meio da transição (`hasStartedIncoming`), a UI já está mostrando a Música B (`incomingDeck`),
        // então qualquer seek do usuário promove a Música B imediatamente como deck único e faz seek nela!
        if hasStartedIncoming, incomingDeck.file != nil {
            let outgoing = activeDeck
            resetDeckNode(outgoing)
            outgoing.file = nil
            outgoing.songId = nil
            outgoing.nominalBPM = 0
            outgoing.timePitch.rate = 1.0
            outgoing.playerNode.volume = 1.0
            activeIndex = (activeIndex == 0) ? 1 : 0
        }
        guard let file = activeDeck.file else { return }
        let wasPlaying = isPlaying
        postTransitionRecoverDuration = 0
        resetTransitionState()
        reportLiveBPM(nil, trend: 0)
        resetDeckNode(activeDeck)

        let clamped = min(max(seconds, 0), max(activeDeck.fileDuration - 0.5, 0))
        activeDeck.segmentStartSec = clamped
        lastKnownTime = clamped
        activeDeck.timePitch.rate = 1.0
        activeDeck.resetDSPToNeutral()
        activeDeck.playerNode.volume = 1.0

        let streamer = DeckPCMStreamer(fileURL: file.url, startAtSec: clamped, node: activeDeck.playerNode)
        activeDeck.streamer = streamer
        _ = streamer.primeAndStartStreaming(syncBuffers: 1, totalInitialBuffers: 3)

        if wasPlaying {
            ensureRunning()
            activeDeck.playerNode.play()
            activeDeck.isPaused = false
            startMonitoring()
        }
        reportPhase(.playing, plan: nil)
        onTimeUpdate?(clamped, activeDeck.fileDuration)
    }

    func pause() {
        stopMonitoring()
        activeDeck.playerNode.pause()
        activeDeck.isPaused = true
        if hasStartedIncoming || hasTriggeredPlayAtFuture {
            incomingDeck.playerNode.pause()
            incomingDeck.isPaused = true
        }
        engine.pause()
        isPlaying = false
    }

    func resume() {
        guard activeDeck.file != nil else { return }
        ensureRunning()
        activeDeck.playerNode.play()
        activeDeck.isPaused = false
        if hasStartedIncoming || hasTriggeredPlayAtFuture {
            incomingDeck.playerNode.play()
            incomingDeck.isPaused = false
        }
        isPlaying = true
        startMonitoring()
    }

    func stop() {
        stopMonitoring()
        postTransitionRecoverDuration = 0
        resetTransitionState()
        reportLiveBPM(nil, trend: 0)
        for d in decks {
            resetDeckNode(d)
            d.file = nil
            d.songId = nil
            d.nominalBPM = 0
            d.timePitch.rate = 1.0
            d.playerNode.volume = 1.0
        }
        if engine.isRunning {
            engine.stop()
        }
        isPlaying = false
        reportPhase(.idle, plan: nil)
    }

    // MARK: - Loop de Controle a 60 Hz (Rampa de BPM + Trigger Hardware AVAudioTime + Sobreposição + EQ + Filtros DJ)

    private func startMonitoring() {
        stopMonitoring()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitorTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func resetTransitionState() {
        hasStartedIncoming = false
        hasTriggeredPlayAtFuture = false
        transitionPlan = nil
        incomingSongId = nil
        if postTransitionRecoverDuration <= 0.05 {
            reportLiveBPM(nil, trend: 0)
        }
        reportPhase(.playing, plan: nil)
    }

    private func reportLiveBPM(_ bpm: Double?, trend: Int) {
        let tenths: Int? = bpm.map { Int(($0 * 10.0).rounded()) }
        if tenths == lastEmittedLiveBPMTenths && trend == lastEmittedLiveBPMTrend {
            return
        }
        lastEmittedLiveBPMTenths = tenths
        lastEmittedLiveBPMTrend = trend
        onLiveBPMChanged?(bpm, trend)
    }

    private func reportPhase(_ phase: Phase, plan: TransitionPlan?) {
        guard phase != lastReportedPhase else { return }
        lastReportedPhase = phase
        onPhaseChanged?(phase, plan)
    }

    private func monitorTick() {
        guard isPlaying, engine.isRunning, activeDeck.file != nil else { return }
        if let validA = validRenderTime(for: activeDeck) {
            lastKnownTime = validA
        }
        if hasStartedIncoming, let validB = validRenderTime(for: incomingDeck) {
            incomingLastKnownTime = validB
        }
        let t = lastKnownTime
        let dur = activeDeck.fileDuration

        // Se a transição já começou (`hasStartedIncoming`), reporta o tempo e a duração da Música B para a UI!
        let uiDeck = uiReportingDeck
        let uiTime = hasStartedIncoming ? max(incomingLastKnownTime, uiDeck.segmentStartSec) : t
        onTimeUpdate?(uiTime, uiDeck.fileDuration)

        // Se a Faixa B acabou de assumir com `initialRateB != 1.0`, volta suavemente para `1.0x` nos primeiros compassos
        if postTransitionRecoverDuration > 0.05 && !hasStartedIncoming {
            let elapsed = t - postTransitionRecoverStartTime
            if elapsed >= postTransitionRecoverDuration || elapsed < -0.5 {
                activeDeck.timePitch.rate = 1.0
                postTransitionRecoverDuration = 0
                reportLiveBPM(nil, trend: 0)
            } else if elapsed >= 0 {
                let rp = Float(min(max(elapsed / postTransitionRecoverDuration, 0.0), 1.0))
                activeDeck.timePitch.rate = postTransitionRateStart + (1.0 - postTransitionRateStart) * rp
                if activeDeck.nominalBPM > 0 {
                    let liveBPM = activeDeck.nominalBPM * Double(activeDeck.timePitch.rate)
                    let trend = postTransitionRateStart < 1.0 ? 1 : -1
                    reportLiveBPM(liveBPM, trend: trend)
                }
            }
        }

        guard let plan = transitionPlan, incomingDeck.file != nil, let nextId = incomingSongId else {
            if dur > 1, t >= dur - 0.15 {
                stopMonitoring()
                resetDeckNode(activeDeck)
                isPlaying = false
                reportLiveBPM(nil, trend: 0)
                reportPhase(.idle, plan: nil)
                onTrackEndedWithoutNext?()
            }
            return
        }

        let isBeatmatch = (plan.transitionType == "beatmatch")
        let safeMixStart = min(plan.trackA.mixStartSec, max(2.0, dur - 2.0))
        let safeMixEnd = min(max(plan.trackA.mixEndSec, safeMixStart + 2.0), max(dur - 0.12, safeMixStart + 0.5))
        let safeRampStart = min(plan.trackA.rampStartSec, safeMixStart)

        // 1. Fase da Rampa de BPM / Cue antes da Faixa B entrar
        let hasRateRamp = isBeatmatch && abs(plan.sync.targetRateA - 1.0) >= 0.003 && plan.sync.rampDurationSec > 0.05 && safeRampStart < safeMixStart - 0.1
        let twoBars = (4.0 * 60.0 / max(plan.trackA.bpm, 60.0)) * 2.0
        let cueLeadStart = max(0.0, safeMixStart - min(twoBars, safeMixStart * 0.20))

        if hasRateRamp, t >= safeRampStart && t < safeMixStart {
            postTransitionRecoverDuration = 0
            let totalLeadSec = max(safeMixStart - safeRampStart, 0.05)
            let activeRampSec = (plan.sync.rampDurationSec > 0.05 && plan.sync.rampDurationSec < totalLeadSec - 0.15)
                ? plan.sync.rampDurationSec
                : totalLeadSec
            let progress = min(max((t - safeRampStart) / activeRampSec, 0.0), 1.0)
            activeDeck.timePitch.rate = 1.0 + (plan.sync.targetRateA - 1.0) * Float(progress)
            reportPhase(.ramping, plan: plan)
            if plan.trackA.bpm > 0 {
                let liveBPM = plan.trackA.bpm * Double(activeDeck.timePitch.rate)
                let trend = progress < 0.995 ? (plan.sync.targetRateA > 1.0 ? 1 : -1) : 0
                reportLiveBPM(liveBPM, trend: trend)
            }
        } else if !hasRateRamp, t >= cueLeadStart && t < safeMixStart {
            reportPhase(.ramping, plan: plan)
        }

        // 2. Disparo sample-accurate (< 1 ms) da Faixa B com silêncio de pré-rolagem exato em frames:
        //    Inicia ~160 ms antes do downbeat para que ambos os `AVAudioUnitTimePitch` compartilhem o mesmo
        //    lookahead (~75 ms) e as duas batidas saiam no mainMixerNode coladas no mesmo milissegundo.
        if !hasTriggeredPlayAtFuture {
            let timeUntilMixStart = safeMixStart - t
            if timeUntilMixStart <= 0.16 {
                hasTriggeredPlayAtFuture = true
                postTransitionRecoverDuration = 0
                ensureRunning()
                if isBeatmatch {
                    activeDeck.timePitch.rate = plan.sync.targetRateA
                    incomingDeck.timePitch.rate = plan.sync.initialRateB ?? 1.0
                }

                let rateA = Double(max(activeDeck.timePitch.rate, 0.5))
                let rateB = Double(max(incomingDeck.timePitch.rate, 0.5))
                // Ambos os playerNodes compartilham o mesmo relógio de pull do AVAudioEngine/TimePitch;
                // não subtrair `hostElapsed` (cujo hostTime atrás do TimePitch defasa ~40 ms no iOS).
                let wallSecUntilA = max(0.0, timeUntilMixStart / rateA)
                let silenceFramesB = Int(round(wallSecUntilA * rateB * Self.renderFormat.sampleRate))

                incomingDeck.prerollSilenceSec = Double(silenceFramesB) / Self.renderFormat.sampleRate
                _ = incomingDeck.streamer?.commitPendingAndStartStreaming(prerollSilenceFrames: silenceFramesB)
                incomingDeck.playerNode.play()
                incomingDeck.isPaused = false

                print(String(format: "[SYNC-LOCK] Preroll disparado | remA=%.1fms | silenceB=%.1fms (%d fr)",
                             timeUntilMixStart * 1000.0,
                             incomingDeck.prerollSilenceSec * 1000.0, silenceFramesB))
            }
        }

        // 2b. No exato instante em que o silêncio termina e o Beat 1 da Faixa B entra: atualiza UI e fase
        if hasTriggeredPlayAtFuture && !hasStartedIncoming && t >= safeMixStart - 0.008 {
            hasStartedIncoming = true
            onTransitionStarted?(nextId)
            reportPhase(.mixing, plan: plan)
            if isBeatmatch && plan.trackB.bpm > 0 {
                reportLiveBPM(plan.trackB.bpm * Double(incomingDeck.timePitch.rate), trend: 0)
            } else {
                reportLiveBPM(nil, trend: 0)
            }
            let uiDeck = uiReportingDeck
            onTimeUpdate?(currentTime(for: uiDeck), uiDeck.fileDuration)
        }

        // 3. Fase da Mixagem Completa: Curva de Volume (Sobrepor) + EQ Central/3-Bandas + Filtros Passa-Alta/Baixa + Reverb
        if hasStartedIncoming {
            let mixDuration = max(safeMixEnd - safeMixStart, 0.5)
            let p = Float(min(max((t - safeMixStart) / mixDuration, 0.0), 1.0))
            applyTransitionDSP(progress: p, plan: plan, outgoing: activeDeck, incoming: incomingDeck, primeOnlyIncoming: false)
            onMixProgress?(p)
        }

        // 4. Fim da transição: promove o Deck B como novo Deck ativo sem interromper o áudio
        if hasStartedIncoming && (t >= safeMixEnd || t >= dur - 0.1) {
            let outgoing = activeDeck
            let incoming = incomingDeck
            let currentRateB = incoming.timePitch.rate

            resetDeckNode(outgoing)
            outgoing.file = nil
            outgoing.songId = nil
            outgoing.nominalBPM = 0
            outgoing.timePitch.rate = 1.0
            outgoing.playerNode.volume = 1.0

            incoming.playerNode.volume = 1.0
            incoming.resetDSPToNeutral()

            activeIndex = (activeIndex == 0) ? 1 : 0
            if abs(currentRateB - 1.0) > 0.004 {
                postTransitionRateStart = currentRateB
                postTransitionRecoverStartTime = currentTime(for: incoming)
                postTransitionRecoverDuration = 5.0
                if incoming.nominalBPM > 0 {
                    reportLiveBPM(incoming.nominalBPM * Double(currentRateB), trend: currentRateB < 1.0 ? 1 : -1)
                }
            } else {
                incoming.timePitch.rate = 1.0
                postTransitionRecoverDuration = 0
                reportLiveBPM(nil, trend: 0)
            }

            resetTransitionState()
            onTransitionCompleted?(nextId)
        }
    }

    // MARK: - Processamento DSP Completo (Volume + EQ + Filtros + Reverb)

    private func applyTransitionDSP(
        progress p: Float,
        plan: TransitionPlan,
        outgoing: DeckChannel,
        incoming: DeckChannel,
        primeOnlyIncoming: Bool
    ) {
        let bars = max(plan.mix.bars ?? 8, 2)
        let oneBarFrac = min(max(1.0 / Float(bars), 0.10), 0.45)

        // 1. FILTROS PASSA-ALTA / PASSA-BAIXA (resolvido antes para coordenar volume da saída)
        let filterStyle = AutomixFilterStyle(rawValue: plan.mix.filterStyle ?? "") ?? .hpInHpOut
        let useReverbTail = (plan.mix.reverbTail == true) || (filterStyle == .finalNoiseOut)

        // 2. CURVA DE VOLUME (quando a Faixa A sai em Passa-Alta, mantém volume cheio e deixa o filtro limpar a saída!)
        let volStyle = AutomixVolumeCurve(rawValue: plan.mix.volumeCurve ?? "") ?? .overlap
        let (volA, volB) = computeVolumes(progress: p, curve: volStyle, filterStyle: filterStyle, oneBarFrac: oneBarFrac)
        if !primeOnlyIncoming {
            outgoing.playerNode.volume = volA
            incoming.playerNode.volume = volB
        }

        // 3. ESTILO DE EQ (Troca de Graves no meio da transição / 3 Bandas / Corte Rápido ou Longo)
        let eqStyle = AutomixEQStyle(rawValue: plan.mix.eqStyle ?? "") ?? .centerBassSwap
        let cutDb = min(plan.mix.eqSwap.bassCutDb, -20.0) // Garante corte real (-24 dB) mesmo quando antes era fade
        applyEQ(progress: p, style: eqStyle, cutDb: cutDb, swapCenter: Float(plan.mix.eqSwap.bassSwapAtProgress), outgoing: outgoing, incoming: incoming, primeOnlyIncoming: primeOnlyIncoming)

        // 4. APLICA FILTROS PASSA-ALTA / PASSA-BAIXA + SAÍDA DE RUÍDO FINAL (WASH-OUT)
        applyFilters(progress: p, style: filterStyle, useReverbTail: useReverbTail, outgoing: outgoing, incoming: incoming, primeOnlyIncoming: primeOnlyIncoming)
    }

    private func computeVolumes(progress p: Float, curve: AutomixVolumeCurve, filterStyle: AutomixFilterStyle, oneBarFrac: Float) -> (Float, Float) {
        let isHPFilterExit: Bool = {
            switch filterStyle {
            case .auto, .hpOut, .hpInHpOut, .lpInHpOut, .partialHpOut, .finalNoiseOut: return true
            default: return false
            }
        }()

        switch curve {
        case .auto, .overlap:
            // SOBREPOR: Faixa B sobe rápido no 1º quarto (até 0.22).
            // Quando a Faixa A sai via Passa-Alta, segura 100% de volume até 0.92 (o filtro limpa a faixa sem "abaixar o fader"!).
            let vB = p < 0.22 ? sin((p / 0.22) * (.pi / 2.0)) : 1.0
            let holdUntil: Float = isHPFilterExit ? 0.92 : 0.82
            let vA = p < holdUntil ? 1.0 : cos(((p - holdUntil) / max(1.0 - holdUntil, 0.01)) * (.pi / 2.0))
            return (vA, vB)

        case .smoothCrossfade:
            // Fade cruzado suave (Equal-power cos/sin)
            return (cos(p * .pi / 2.0), sin(p * .pi / 2.0))

        case .fadeInFadeOut:
            // Fade in / Fade out linear simétrico
            return (1.0 - p, p)

        case .cutInFadeOut:
            // Corte na entrada (B entra direto a 100% no Beat 1) com fade out na A a partir do meio
            let r = min(p / 0.025, 1.0)
            let vA = p < 0.35 ? 1.0 : max(0.0, 1.0 - ((p - 0.35) / 0.65))
            return (vA, r)

        case .fadeInCutOut:
            // Fade in na B enquanto A segura 100% até o corte seco no final da frase
            let vB = min(p / 0.75, 1.0)
            let vA: Float = p < 0.95 ? 1.0 : max(0.0, 1.0 - ((p - 0.95) / 0.05))
            return (vA, vB)

        case .centerCut:
            // Corte central: A e B se encontram no meio (50%) e A corta exatamente na virada central do compasso
            let vB = p < 0.50 ? min(p / 0.45, 1.0) : 1.0
            let vA: Float = p < 0.50 ? 1.0 : max(0.0, 1.0 - ((p - 0.50) / 0.05))
            return (vA, vB)

        case .crossfadeQuickOut:
            // Fade in com saída rápida: B sobe até 0.55; A segura 100% até 0.55 e sai rápido
            let vB = min(p / 0.55, 1.0)
            let vA = p < 0.55 ? 1.0 : max(0.0, 1.0 - ((p - 0.55) / 0.45))
            return (vA, vB)

        case .fadeIn1BarCutOut:
            // Fade in de 1 compasso na B + sobreposição total + corte na saída da A
            let vB = min(p / oneBarFrac, 1.0)
            let vA: Float = p < 0.95 ? 1.0 : max(0.0, 1.0 - ((p - 0.95) / 0.05))
            return (vA, vB)

        case .overlap1BarCutOut:
            // Sobreposição pura no último compasso com corte seco na saída
            let startB = max(0.0, 1.0 - oneBarFrac)
            let vB: Float = p < startB ? 0.0 : min((p - startB) / 0.025, 1.0)
            let vA: Float = p < 0.96 ? 1.0 : max(0.0, 1.0 - ((p - 0.96) / 0.04))
            return (vA, vB)
        }
    }

    private func applyEQ(
        progress p: Float,
        style: AutomixEQStyle,
        cutDb: Float,
        swapCenter: Float,
        outgoing: DeckChannel,
        incoming: DeckChannel,
        primeOnlyIncoming: Bool
    ) {
        let outBands = outgoing.eq.bands
        let inBands = incoming.eq.bands
        guard outBands.count >= 3, inBands.count >= 3 else { return }

        func applyBassWindow(center: Float, width: Float) {
            let lo = max(0.0, center - width * 0.5)
            let hi = min(1.0, center + width * 0.5)
            let s: Float
            if p <= lo { s = 0.0 }
            else if p >= hi { s = 1.0 }
            else { s = (p - lo) / max(hi - lo, 0.001) }

            if !primeOnlyIncoming {
                outBands[0].gain = cutDb * s
                outBands[1].gain = 0.0
                outBands[2].gain = 0.0
            }
            inBands[0].gain = cutDb * (1.0 - s)
            inBands[1].gain = 0.0
            inBands[2].gain = 0.0
        }

        switch style {
        case .auto, .centerBassSwap:
            // Troca de Grave Central (50% da transição)
            applyBassWindow(center: swapCenter > 0.05 ? swapCenter : 0.50, width: 0.14)

        case .startBassSwap:
            // Início da troca de graves (~20% da transição)
            applyBassWindow(center: 0.20, width: 0.14)

        case .endBassSwap:
            // Fim da troca de graves (~80% da transição)
            applyBassWindow(center: 0.80, width: 0.14)

        case .quickBassCut:
            // Corte rápido de graves exatamente na virada central do compasso (janela de 3%)
            applyBassWindow(center: 0.50, width: 0.03)

        case .longBassCut:
            // Corte longo e progressivo de graves ao longo de 70% da transição
            applyBassWindow(center: 0.50, width: 0.70)

        case .bassFadeOut:
            // Fade out contínuo dos graves da A desde 0% até 75%, enquanto o grave da B sobe de 25% a 85%
            let sA = min(max(p / 0.75, 0.0), 1.0)
            let sB = min(max((p - 0.25) / 0.60, 0.0), 1.0)
            if !primeOnlyIncoming {
                outBands[0].gain = cutDb * sA
                outBands[1].gain = 0.0
                outBands[2].gain = 0.0
            }
            inBands[0].gain = cutDb * (1.0 - sB)
            inBands[1].gain = 0.0
            inBands[2].gain = 0.0

        case .threeBandTransition:
            // Transição completa de 3 Bandas tipo Mixer DJ (Isolator Low -> Mid -> High escalonados):
            // 1º: Agudos da B entram (0.05..0.35) e Agudos da A recuam no fim (0.65..0.95)
            // 2º: Graves trocam de golpe no centro (0.44..0.56)
            // 3º: Médios/Vocais trocam logo após o centro (0.45..0.78) evitando choque vocal durante a sobreposição!
            let lowS = min(max((p - 0.44) / 0.12, 0.0), 1.0)
            let midInS = min(max((p - 0.25) / 0.45, 0.0), 1.0)
            let midOutS = min(max((p - 0.48) / 0.38, 0.0), 1.0)
            let highInS = min(max((p - 0.05) / 0.30, 0.0), 1.0)
            let highOutS = min(max((p - 0.65) / 0.30, 0.0), 1.0)

            let midCut: Float = -15.0
            let highCut: Float = -14.0

            if !primeOnlyIncoming {
                outBands[0].gain = cutDb * lowS
                outBands[1].gain = midCut * midOutS
                outBands[2].gain = highCut * highOutS
            }
            inBands[0].gain = cutDb * (1.0 - lowS)
            inBands[1].gain = midCut * (1.0 - midInS)
            inBands[2].gain = highCut * (1.0 - highInS)
        }
    }

    private func applyFilters(
        progress p: Float,
        style: AutomixFilterStyle,
        useReverbTail: Bool,
        outgoing: DeckChannel,
        incoming: DeckChannel,
        primeOnlyIncoming: Bool
    ) {
        let outBands = outgoing.eq.bands
        let inBands = incoming.eq.bands
        guard outBands.count >= 5, inBands.count >= 5 else { return }

        // Interpolação exponencial de frequência (natural ao ouvido humano)
        func expFreq(from f0: Float, to f1: Float, t: Float) -> Float {
            let clamped = min(max(t, 0.0), 1.0)
            return f0 * pow(f1 / f0, clamped)
        }

        // Reseta filtros por padrão antes de ativar os necessários do estilo atual
        var outHP: Float? = nil
        var outLP: Float? = nil
        var inHP: Float? = nil
        var inLP: Float? = nil

        // Na entrada (B): o filtro atua na 1ª metade (p: 0.0 -> 0.52) abrindo exatamente no drop/troca central
        let inSweep = min(max(p / 0.52, 0.0), 1.0)
        // Na saída (A): o filtro começa a varrer a partir do meio da transição (p: 0.45 -> 1.0)
        let outSweep = min(max((p - 0.45) / 0.55, 0.0), 1.0)

        switch style {
        case .none:
            break

        case .lpOut:
            // Passa-baixa na saída (abafa a Faixa A de 18 kHz até 280 Hz na saída)
            outLP = expFreq(from: 18_000, to: 280, t: outSweep)

        case .lpIn:
            // Passa-baixa na entrada (Faixa B surge abafada de 320 Hz abrindo até 18 kHz no meio)
            inLP = expFreq(from: 320, to: 18_000, t: inSweep)

        case .lpInLpOut:
            inLP = expFreq(from: 320, to: 18_000, t: inSweep)
            outLP = expFreq(from: 18_000, to: 280, t: outSweep)

        case .lpInHpOut:
            inLP = expFreq(from: 320, to: 18_000, t: inSweep)
            outHP = expFreq(from: 25, to: 2_600, t: outSweep)

        case .hpOut:
            // Passa-alta na saída (Faixa A mantém volume cheio e afina de 25 Hz até 3400 Hz na metade final)
            outHP = expFreq(from: 25, to: 3_400, t: outSweep)

        case .hpIn:
            // Passa-alta na entrada (Faixa B entra sem peso em 1400 Hz e desce até 20 Hz no drop central)
            inHP = expFreq(from: 1_400, to: 20, t: inSweep)

        case .auto, .hpInHpOut:
            inHP = expFreq(from: 1_200, to: 20, t: inSweep)
            outHP = expFreq(from: 25, to: 3_200, t: outSweep)

        case .hpInLpOut:
            inHP = expFreq(from: 1_200, to: 20, t: inSweep)
            outLP = expFreq(from: 18_000, to: 300, t: outSweep)

        case .partialHpOut:
            // Passa-alta parcial na saída (tira o corpo/médio-grave da A até 750 Hz mantendo os vocais/hi-hats limpos)
            outHP = expFreq(from: 25, to: 750, t: outSweep)

        case .finalNoiseOut:
            // Saída de ruído final / Wash-out (High-Pass agressivo até 3.4 kHz + cauda espacial de Reverb Hall)
            outHP = expFreq(from: 25, to: 3_400, t: outSweep)
            inHP = expFreq(from: 900, to: 20, t: inSweep)
        }

        if !primeOnlyIncoming {
            if let f = outHP, f > 28.0 {
                outBands[3].frequency = f
                outBands[3].bypass = false
            } else {
                outBands[3].frequency = 20.0
                outBands[3].bypass = true
            }

            if let f = outLP, f < 17_500.0 {
                outBands[4].frequency = f
                outBands[4].bypass = false
            } else {
                outBands[4].frequency = 20_000.0
                outBands[4].bypass = true
            }

            if useReverbTail && p > 0.45 {
                let revProgress = min(max((p - 0.45) / 0.55, 0.0), 1.0)
                outgoing.reverb.wetDryMix = revProgress * 58.0
            } else {
                outgoing.reverb.wetDryMix = 0.0
            }
        }

        if let f = inHP, f > 28.0 {
            inBands[3].frequency = f
            inBands[3].bypass = false
        } else {
            inBands[3].frequency = 20.0
            inBands[3].bypass = true
        }

        if let f = inLP, f < 17_500.0 {
            inBands[4].frequency = f
            inBands[4].bypass = false
        } else {
            inBands[4].frequency = 20_000.0
            inBands[4].bypass = true
        }
        incoming.reverb.wetDryMix = 0.0
    }
}
