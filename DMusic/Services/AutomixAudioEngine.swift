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
        /// - Band 0: Low Shelf (250 Hz) -> Bass Swap / Corte de Graves
        /// - Band 1: Parametric Mid (1 kHz, BW 3 oct) -> Transição de 3 Bandas (Médios/Vocais)
        /// - Band 2: High Shelf (2.2 kHz) -> Transição de 3 Bandas (Agudos/Brilho)
        /// Frequências do EQ do rekordbox (tipo DJM-900NXS2): shelf 250 Hz, peak 1 kHz bem largo, shelf 2.2 kHz.
        /// - Band 3: High-Pass Filter (20 Hz a 3600 Hz) -> Filtro Passa-Alta DJ (Entrada/Saída)
        /// - Band 4: Low-Pass Filter (240 Hz a 20000 Hz) -> Filtro Passa-Baixa DJ (Entrada/Saída)
        let eq = AVAudioUnitEQ(numberOfBands: 5)
        let reverb = AVAudioUnitReverb()

        var file: AVAudioFile?
        var songId: String?
        var nominalBPM: Double = 0
        var loudnessLUFS: Float? = nil
        var loudnessPeakDB: Float? = nil
        var streamer: DeckPCMStreamer?
        var segmentStartSec: Double = 0
        var prerollSilenceSec: Double = 0
        var fileDuration: Double = 0
        var isPaused = false


        init() {
            let b = eq.bands
            if b.count >= 5 {
                // Band 0: Graves (Low Shelf 250 Hz) — corta também o corpo do baixo (185–300 Hz) na troca de graves
                b[0].filterType = .lowShelf
                b[0].frequency = 250.0
                b[0].gain = 0.0
                b[0].bypass = false

                // Band 1: Médios (Parametric 1 kHz, ~3 oitavas: ~350 Hz a ~2.8 kHz)
                b[1].filterType = .parametric
                b[1].frequency = 1000.0
                b[1].bandwidth = 3.0
                b[1].gain = 0.0
                b[1].bypass = false

                // Band 2: Agudos (High Shelf 2.2 kHz)
                b[2].filterType = .highShelf
                b[2].frequency = 2200.0
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
            reverb.bypass = true // reverb Hall com 0% de efeito ainda custa CPU: só liga quando houver cauda
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
            reverb.bypass = true
        }
    }

    private static let renderFormat = DeckPCMStreamer.renderFormat

    private let engine = AVAudioEngine()
    private let decks = [DeckChannel(), DeckChannel()]
    /// Barramento de soma dos dois decks -> Peak Limiter -> mainMixerNode (evita clipping quando A e B tocam juntas)
    private let mixBus = AVAudioMixerNode()
    private let masterLimiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
    private var activeIndex = 0
    private var isSetup = false
    private var monitorTimer: Timer?
    private var monitorInterval: TimeInterval = 0
    private var lastUIEmit: CFAbsoluteTime = 0
    /// Intervalo mínimo entre atualizações de posição para a interface (o gerenciador usa 0,1 s com o player aberto e 0,5 s fora dele).
    var uiUpdateInterval: TimeInterval = 0.5 {
        didSet {
            // Player aberto/fechado: reajusta a cadência na hora e já manda uma atualização para a tela
            lastUIEmit = 0
            guard monitorTimer != nil else { return }
            let desired = desiredMonitorInterval()
            if abs(desired - monitorInterval) > 0.0005 { scheduleMonitor(every: desired) }
        }
    }
    /// Incrementado a cada nova preparação (e em todo reset de transição) para descartar análises em segundo plano obsoletas
    private var prepareGeneration = 0
    /// Enquanto a análise da Faixa B roda em segundo plano, segura o disparo de uma transição armada anteriormente
    private var isPreparingIncoming = false

    // Estado da transição preparada para o par atual -> próximo
    private var transitionPlan: TransitionPlan?
    private var incomingSongId: String?
    private var hasStartedIncoming = false
    private var hasTriggeredPlayAtFuture = false
    private var lastReportedPhase: Phase = .idle
    private var lastKnownTime: Double = 0
    private var incomingLastKnownTime: Double = 0
    private var lastloggedPLLTime: Double = 0
    private(set) var livePhaseErrorMs: Double = 0
    private(set) var isPLLCorrecting: Bool = false
    private var configObserver: NSObjectProtocol?
    private(set) var isPlaying = false
    var isEngineRunning: Bool { engine.isRunning }

    var volumeCompensation: VolumeCompensationLevel = .off {
        didSet { reapplyLoudnessGain() }
    }

    /// Loudness integrada (LUFS) segundo ITU-R BS.1770-4: filtro K (shelf de agudos + passa-alta de 38 Hz),
    /// blocos de 400 ms com 75% de sobreposição, gate absoluto de -70 LUFS e gate relativo de -10 LU.
    /// Para não decodificar o arquivo inteiro, mede 12 janelas de 3.2 s espalhadas pela faixa (ou a faixa toda se for curta).
    /// Também devolve o pico de amostra (dBFS) dessas janelas para a proteção contra clipping.
    /// Custo de alguns décimos de segundo: chamar sempre fora da main thread.
    nonisolated static func measureLoudness(url: URL) -> (lufs: Float, peakDB: Float)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        let chCount = min(Int(file.processingFormat.channelCount), 2)
        guard sr >= 8_000, totalFrames > Int64(sr * 1.0), chCount > 0 else { return nil }

        // Coeficientes do filtro K para a taxa do arquivo (fórmulas de referência do BS.1770 / libebur128)
        let shelf: [Double] = {
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / sr)
            let vh = pow(10.0, g / 20.0)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1.0 + k / q + k * k
            return [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                    2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0]
        }()
        let highPass: [Double] = {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / sr)
            let a0 = 1.0 + k / q + k * k
            return [1.0, -2.0, 1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0]
        }()

        let subBlockFrames = max(Int(sr * 0.1), 1) // 100 ms; um bloco de 400 ms = 4 sub-blocos
        let windowCount: Int
        let windowFrames: Int
        if Double(totalFrames) / sr <= 40.0 {
            windowCount = 1
            windowFrames = Int(totalFrames)
        } else {
            windowCount = 12
            windowFrames = subBlockFrames * 32
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(subBlockFrames)) else { return nil }

        var blockPowers: [Double] = []
        var maxPeak: Float = 0.0001

        for w in 0..<windowCount {
            let frac = windowCount == 1 ? 0.0 : 0.08 + 0.84 * Double(w) / Double(windowCount - 1)
            let start = min(max(0, Int64(Double(totalFrames) * frac)), max(0, totalFrames - Int64(windowFrames)))
            file.framePosition = start

            // Estado dos dois biquads (TDF-II) por canal; zerado em cada janela
            var z = [[Double]](repeating: [0, 0, 0, 0], count: chCount)
            var subPowers: [Double] = []
            var framesLeft = windowFrames

            while framesLeft >= subBlockFrames {
                buf.frameLength = 0
                guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(subBlockFrames))) != nil,
                      Int(buf.frameLength) == subBlockFrames,
                      let channels = buf.floatChannelData else { break }
                framesLeft -= subBlockFrames

                var power = 0.0
                for ch in 0..<chCount {
                    let x = channels[ch]
                    var pk: Float = 0
                    vDSP_maxmgv(x, 1, &pk, vDSP_Length(subBlockFrames))
                    if pk > maxPeak { maxPeak = pk }

                    var s1 = z[ch][0], s2 = z[ch][1], h1 = z[ch][2], h2 = z[ch][3]
                    var sum = 0.0
                    for i in 0..<subBlockFrames {
                        let xi = Double(x[i])
                        let y1 = shelf[0] * xi + s1
                        s1 = shelf[1] * xi - shelf[3] * y1 + s2
                        s2 = shelf[2] * xi - shelf[4] * y1
                        let y2 = highPass[0] * y1 + h1
                        h1 = highPass[1] * y1 - highPass[3] * y2 + h2
                        h2 = highPass[2] * y1 - highPass[4] * y2
                        sum += y2 * y2
                    }
                    z[ch] = [s1, s2, h1, h2]
                    // Canais L/R têm peso 1.0 no BS.1770
                    power += sum / Double(subBlockFrames)
                }
                subPowers.append(power)
            }

            // Descarta os 2 primeiros sub-blocos (transiente do filtro após o salto) e monta blocos de 400 ms com hop de 100 ms
            if subPowers.count >= 6 {
                for i in 2...(subPowers.count - 4) {
                    blockPowers.append((subPowers[i] + subPowers[i + 1] + subPowers[i + 2] + subPowers[i + 3]) / 4.0)
                }
            }
        }

        func lufs(_ power: Double) -> Double { -0.691 + 10.0 * log10(max(power, 1e-12)) }
        let absGated = blockPowers.filter { lufs($0) > -70.0 }
        guard !absGated.isEmpty else { return nil }
        let relThreshold = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10.0
        let relGated = absGated.filter { lufs($0) > relThreshold }
        guard !relGated.isEmpty else { return nil }
        let integrated = lufs(relGated.reduce(0, +) / Double(relGated.count))
        return (Float(integrated), 20.0 * log10(maxPeak))
    }

    nonisolated static func computeGainDB(lufs: Float, peakDB: Float, level: VolumeCompensationLevel) -> Float {
        guard level != .off else { return 0.0 }
        let desired = level.targetLUFS - lufs
        let clamped = min(max(desired, level.maxCutDB), level.maxBoostDB)
        // Proteção contra clipping: nunca empurra o pico acima de -0.5 dBFS
        let peakSafe = min(clamped, -0.5 - peakDB)
        return max(peakSafe, level.maxCutDB)
    }

    private func applyLoudness(to deck: DeckChannel, fileURL: URL?, songId: String?) {
        // Compensação desligada: não decodifica nada e o deck toca no ganho original
        guard volumeCompensation != .off, let songId else {
            deck.loudnessLUFS = nil
            deck.loudnessPeakDB = nil
            deck.eq.globalGain = 0.0
            return
        }
        if let cached = LoudnessCache.shared.get(songId) {
            deck.loudnessLUFS = cached.lufs
            deck.loudnessPeakDB = cached.peakDB
            deck.eq.globalGain = Self.computeGainDB(lufs: cached.lufs, peakDB: cached.peakDB, level: volumeCompensation)
            return
        }

        // Ainda sem medição: toca em ganho neutro e mede em segundo plano (nunca decodifica na main thread)
        deck.loudnessLUFS = nil
        deck.loudnessPeakDB = nil
        deck.eq.globalGain = 0.0
        guard let url = fileURL else { return }
        Task { [weak self] in
            let measured = await Task.detached(priority: .utility) { Self.measureLoudness(url: url) }.value
            guard let self, let measured else { return }
            LoudnessCache.shared.set(songId, lufs: measured.lufs, peakDB: measured.peakDB)
            guard self.volumeCompensation != .off else { return }
            for d in self.decks where d.songId == songId {
                d.loudnessLUFS = measured.lufs
                d.loudnessPeakDB = measured.peakDB
                d.eq.globalGain = Self.computeGainDB(lufs: measured.lufs, peakDB: measured.peakDB, level: self.volumeCompensation)
            }
        }
    }

    /// Reaplica a compensação nos decks (ao mudar o nível nos ajustes), medindo o que ainda não tiver medição.
    private func reapplyLoudnessGain() {
        for d in decks where d.songId != nil {
            applyLoudness(to: d, fileURL: d.file?.url, songId: d.songId)
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
            Task { await prepareIncoming(fileB: savedFileB, songId: savedSongIdB, plan: savedPlan) }
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
        engine.attach(mixBus)
        engine.attach(masterLimiter)
        engine.connect(mixBus, to: masterLimiter, format: Self.renderFormat)
        engine.connect(masterLimiter, to: engine.mainMixerNode, format: Self.renderFormat)
        // Ataque rápido (2 ms) e liberação curta (50 ms): segura só os picos da soma A+B, sem "bombear" a mix
        masterLimiter.withAudioUnit { unit in
            AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
            AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
            AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0.0, 0)
        }

        for deck in decks {
            engine.attach(deck.playerNode)
            engine.attach(deck.timePitch)
            engine.attach(deck.eq)
            engine.attach(deck.reverb)
            engine.connect(deck.playerNode, to: deck.timePitch, format: Self.renderFormat)
            engine.connect(deck.timePitch, to: deck.eq, format: Self.renderFormat)
            engine.connect(deck.eq, to: deck.reverb, format: Self.renderFormat)
            engine.connect(deck.reverb, to: mixBus, format: Self.renderFormat)
        }
        engine.prepare()
    }

    private func ensureRunning() {
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    /// Para o deck e o deixa ocioso: o TimePitch (algoritmo de esticamento, caro) fica em bypass enquanto só processaria
    /// silêncio. Quem for tocar neste deck precisa chamar `activate(_:)` antes (nunca no meio do áudio: o bypass
    /// muda a latência do TimePitch e desalinharia os dois decks).
    private func resetDeckNode(_ deck: DeckChannel) {
        deck.streamer?.cancel()
        deck.streamer = nil
        deck.playerNode.stop()
        deck.playerNode.reset()
        deck.resetDSPToNeutral()
        deck.prerollSilenceSec = 0
        deck.isPaused = false
        deck.timePitch.bypass = true
    }

    /// Liga o TimePitch de um deck que vai tocar (chamar com o deck parado, antes de agendar áudio).
    private func activate(_ deck: DeckChannel) {
        if deck.timePitch.bypass { deck.timePitch.bypass = false }
    }

    // MARK: - Leitura do tempo interno exato (sample-accurate mesmo com TimePitch ativo)

    /// Snapshot instantâneo O(1) do estado dos dois decks para renderização a 60 FPS no Espectrograma Rekordbox.
    struct LiveDeckSnapshot {
        let songIdA: String?
        let timeA: Double
        let durationA: Double
        let rateA: Float
        let nominalBPMA: Double
        let songIdB: String?
        let timeB: Double
        let durationB: Double
        let rateB: Float
        let nominalBPMB: Double
        let hasStartedIncoming: Bool
        let phase: Phase
        let plan: TransitionPlan?
        var phaseErrorMs: Double = 0
        var isPLLCorrecting: Bool = false
    }

    func liveDeckSnapshot() -> LiveDeckSnapshot {
        let tA = currentTime(for: activeDeck)
        let tB = hasStartedIncoming ? currentTime(for: incomingDeck) : incomingDeck.segmentStartSec
        return LiveDeckSnapshot(
            songIdA: activeDeck.songId,
            timeA: tA,
            durationA: activeDeck.fileDuration,
            rateA: activeDeck.timePitch.rate,
            nominalBPMA: activeDeck.nominalBPM,
            songIdB: incomingDeck.songId,
            timeB: tB,
            durationB: incomingDeck.fileDuration,
            rateB: incomingDeck.timePitch.rate,
            nominalBPMB: incomingDeck.nominalBPM,
            hasStartedIncoming: hasStartedIncoming,
            phase: lastReportedPhase,
            plan: transitionPlan,
            phaseErrorMs: livePhaseErrorMs,
            isPLLCorrecting: isPLLCorrecting
        )
    }

    private func validRenderTime(for deck: DeckChannel) -> Double? {
        guard engine.isRunning, !deck.isPaused, deck.playerNode.isPlaying,
              let nodeTime = deck.playerNode.lastRenderTime,
              let playerTime = deck.playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime > 0 else {
            return nil
        }
        let pRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : Self.renderFormat.sampleRate
        let rawSamples = playerTime.sampleTime
        let prerollSamples = Int64(round(deck.prerollSilenceSec * pRate))
        if rawSamples <= prerollSamples {
            return deck.segmentStartSec
        }
        let elapsedSourceSec = Double(rawSamples - prerollSamples) / pRate
        return min(deck.segmentStartSec + elapsedSourceSec, deck.fileDuration)
    }

    /// Mede o BPM contínuo real local (sem quantização de 5 ms!) diretamente no envelope de bumbos (45–150 Hz)
    /// da janela de transição do arquivo decodificado. Usa hop de 2 ms com suavização triangular de 12 ms
    /// e pente de 1, 2, 4, 8 e 16 batidas (4 compassos) para eliminar falsos desvios de 0.6%–1% e detectar
    /// diferenças reais de andamento (como 145.3 vs 148.1 BPM).
    nonisolated private static func measureLocalTrueBPM(
        url: URL,
        aroundSec: Double,
        windowSec: Double = 28.0,
        hintBPM: Double
    ) -> (bpm: Double, confidence: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        guard sr >= 8_000, totalFrames > Int64(sr * 10.0) else { return nil }
        let dur = Double(totalFrames) / sr

        let startSec = max(0.0, min(aroundSec, dur - windowSec))
        let readDur = min(windowSec, dur - startSec)
        guard readDur >= 10.0 else { return nil }

        let startFrame = AVAudioFramePosition(startSec * sr)
        let frameCount = AVAudioFrameCount(readDur * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }
        file.framePosition = startFrame
        do { try file.read(into: buf, frameCount: frameCount) } catch { return nil }

        let n = Int(buf.frameLength)
        guard n > Int(sr * 8.0), let chData = buf.floatChannelData else { return nil }
        let chCount = Int(buf.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if chCount == 1 {
            memcpy(&mono, chData[0], n * MemoryLayout<Float>.size)
        } else {
            var scale: Float = 1.0 / Float(chCount)
            for c in 0..<chCount {
                vDSP_vsma(chData[c], 1, &scale, mono, 1, &mono, 1, vDSP_Length(n))
            }
        }

        // Passa-faixa de bumbo (45–150 Hz): isola o transiente do kick e remove sub-bass contínuo
        let aLP = Float(1.0 - exp(-2.0 * Double.pi * 150.0 / sr))
        let aHP = Float(1.0 - exp(-2.0 * Double.pi * 45.0 / sr))
        var kick = [Float](repeating: 0, count: n)
        var lp150: Float = 0
        var lp45: Float = 0
        for i in 0..<n {
            let x = mono[i]
            lp150 += aLP * (x - lp150)
            lp45 += aHP * (x - lp45)
            kick[i] = lp150 - lp45
        }

        let hopSec = 0.002 // 2 ms (500 fps)
        let hop = max(1, Int(round(sr * hopSec)))
        let win = hop * 2
        let m = (n - win) / hop
        guard m > 1_000 else { return nil }

        var env = [Float](repeating: 0, count: m)
        for f in 0..<m {
            var rms: Float = 0
            kick.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + f * hop, 1, &rms, vDSP_Length(win))
            }
            env[f] = rms
        }

        var rawFlux = [Float](repeating: 0, count: m)
        for f in 1..<m {
            rawFlux[f] = max(0, env[f] - env[f - 1])
        }

        // Suavização triangular (±3 frames = ±6 ms) para eliminar picos de 1 amostra que travavam lags inteiros
        var flux = [Float](repeating: 0, count: m)
        let kHalf = 3
        for f in kHalf..<(m - kHalf) {
            var s: Float = 0
            for j in -kHalf...kHalf {
                let w = Float(kHalf + 1 - abs(j))
                s += rawFlux[f + j] * w
            }
            flux[f] = s / 16.0
        }

        let baseHint = hintBPM > 50 ? hintBPM : 125.0
        let loBPM = max(65.0, baseHint * 0.90)
        let hiBPM = min(205.0, baseHint * 1.10)

        // Pente multi-compasso (1, 2, 4, 8 e 16 batidas = 4 compassos inteiros!)
        let mults: [(Double, Double)] = [(1.0, 0.7), (2.0, 0.9), (4.0, 1.4), (8.0, 1.5), (16.0, 1.5)]

        func evalScore(for bpm: Double) -> Double {
            let period = (60.0 / bpm) / hopSec
            var score = 0.0
            var weightSum = 0.0
            for (mult, w) in mults {
                let exactLag = period * mult
                let lag0 = Int(floor(exactLag))
                let frac = Float(exactLag - Double(lag0))
                if lag0 < 1 || lag0 + 1 >= m - 40 { continue }
                let count = vDSP_Length(m - lag0 - 1)
                var dot0: Float = 0
                var dot1: Float = 0
                flux.withUnsafeBufferPointer { ptr in
                    let base = ptr.baseAddress!
                    vDSP_dotpr(base, 1, base + lag0, 1, &dot0, count)
                    vDSP_dotpr(base, 1, base + lag0 + 1, 1, &dot1, count)
                }
                let interp = Double(dot0 * (1.0 - frac) + dot1 * frac) / Double(count)
                score += interp * w
                weightSum += w
            }
            return weightSum > 0 ? (score / weightSum) : 0.0
        }

        // 1. Varredura inicial (passo de 0.15 BPM)
        let coarseStep = 0.15
        var bestBPM = baseHint
        var bestScore = -1.0
        var sumScores = 0.0
        var countScores = 0
        var b = loBPM
        while b <= hiBPM {
            let sc = evalScore(for: b)
            sumScores += sc
            countScores += 1
            if sc > bestScore {
                bestScore = sc
                bestBPM = b
            }
            b += coarseStep
        }

        // 2. Refinamento fino contínuo (±0.30 BPM em passos de 0.01 BPM) + interpolação parabólica exata
        var fineBestBPM = bestBPM
        var fineBestScore = bestScore
        let fineStep = 0.01
        var fb = max(loBPM, bestBPM - 0.30)
        let fbEnd = min(hiBPM, bestBPM + 0.30)
        while fb <= fbEnd {
            let sc = evalScore(for: fb)
            if sc > fineBestScore {
                fineBestScore = sc
                fineBestBPM = fb
            }
            fb += fineStep
        }

        let sL = evalScore(for: max(loBPM, fineBestBPM - fineStep))
        let sC = fineBestScore
        let sR = evalScore(for: min(hiBPM, fineBestBPM + fineStep))
        let denom = (sL - 2.0 * sC + sR)
        let exactBPM: Double
        if abs(denom) > 1e-12 {
            let delta = 0.5 * (sL - sR) / denom
            exactBPM = fineBestBPM + min(max(delta, -1.0), 1.0) * fineStep
        } else {
            exactBPM = fineBestBPM
        }

        guard countScores > 0 else { return nil }
        let avgScore = sumScores / Double(countScores)
        let confidence = avgScore > 1e-9 ? (fineBestScore / avgScore) : 0.0
        return (exactBPM, confidence)
    }

    /// Verifica o BPM real exato (sem arredondamentos) de ambas as faixas nas janelas da transição
    /// e só substitui `targetRateA` / `initialRateB` quando o áudio comprovar com alta confiança periódica
    /// que há uma divergência real de andamento (>= 0.85%) em relação ao plano do servidor.
    nonisolated static func refineTransitionPlanWithTrueBPM(
        plan: TransitionPlan,
        urlA: URL,
        urlB: URL
    ) -> TransitionPlan {
        guard plan.transitionType == "beatmatch" else { return plan }

        let winStartA = max(0.0, plan.trackA.mixStartSec - 20.0)
        let winStartB = max(0.0, plan.trackB.entrySec)

        guard let measA = measureLocalTrueBPM(url: urlA, aroundSec: winStartA, windowSec: 28.0, hintBPM: plan.trackA.bpm),
              let measB = measureLocalTrueBPM(url: urlB, aroundSec: winStartB, windowSec: 28.0, hintBPM: plan.trackB.bpm),
              measA.confidence >= 1.75, measB.confidence >= 1.75 else {
            return plan
        }

        let ratios = [
            measB.bpm / measA.bpm,
            (measB.bpm * 2.0) / measA.bpm,
            (measB.bpm * 0.5) / measA.bpm
        ]
        guard let trueRatio = ratios.min(by: { abs(1.0 - $0) < abs(1.0 - $1) }),
              abs(1.0 - trueRatio) <= 0.15 else {
            return plan
        }

        let oldCombinedRatio = Double(plan.sync.targetRateA) / Double(max(plan.sync.initialRateB ?? 1.0, 0.5))
        // Evita alterar planos já precisos do `allin1` por micro-variações (< 0.85%), mas corrige erros reais (ex.: 145.3 vs 148.1 BPM = 2.0%)
        guard abs(trueRatio - oldCombinedRatio) >= 0.0085 else {
            return plan
        }

        var updated = plan
        updated.trackA = TrackATiming(
            id: plan.trackA.id,
            bpm: measA.bpm,
            rampStartSec: plan.trackA.rampStartSec,
            mixStartSec: plan.trackA.mixStartSec,
            mixEndSec: plan.trackA.mixEndSec,
            section: plan.trackA.section
        )
        updated.trackB = TrackBTiming(
            id: plan.trackB.id,
            bpm: measB.bpm,
            entrySec: plan.trackB.entrySec,
            section: plan.trackB.section
        )

        let newRateA: Float
        let newRateB: Float
        if abs(trueRatio - 1.0) <= 0.08 {
            newRateA = Float(min(max(trueRatio, 0.92), 1.08))
            newRateB = 1.0
        } else {
            let clampedA = min(max(trueRatio, 0.92), 1.08)
            newRateA = Float(clampedA)
            newRateB = Float(min(max(clampedA / max(trueRatio, 0.5), 0.93), 1.07))
        }
        updated.sync.targetRateA = newRateA
        updated.sync.initialRateB = newRateB

        // Se o plano original achava que o BPM era igual (sem rampa), cria uma rampa suave variável + hold
        let rateDelta = Double(abs(newRateA - 1.0))
        if rateDelta >= 0.002 && (updated.sync.rampDurationSec < 0.5 || updated.trackA.rampStartSec >= updated.trackA.mixStartSec - 1.0) {
            let barSec = 4.0 * 60.0 / max(measA.bpm, 60.0)
            let rampBars: Double = rateDelta < 0.020 ? 8.0 : (rateDelta < 0.045 ? 10.0 : 12.0)
            let holdBars: Double = rateDelta < 0.020 ? 4.0 : (rateDelta < 0.045 ? 6.0 : 8.0)
            let totalLeadSec = (rampBars + holdBars) * barSec
            let rampStart = max(updated.trackA.mixStartSec * 0.45, updated.trackA.mixStartSec - totalLeadSec)
            let actualLead = max(0.0, updated.trackA.mixStartSec - rampStart)
            updated.trackA.rampStartSec = rampStart
            updated.sync.rampDurationSec = actualLead * (rampBars / (rampBars + holdBars))
        }

        print(String(format: "[SYNC-LOCK] TrueBPM exato: A=%.4f (conf %.1fx) | B=%.4f (conf %.1fx) → RateA=%.5fx RateB=%.5fx (antes %.5fx)",
                     measA.bpm, measA.confidence, measB.bpm, measB.confidence,
                     newRateA, newRateB, plan.sync.targetRateA))
        return updated
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
        activate(deck)
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
    /// Retorna o `TransitionPlan` efetivo (já com BeatSnap / ajustes de seek) para manter a barra de progresso 100% sincronizada.
    /// A análise de áudio roda em segundo plano; retorna `nil` se foi cancelada (seek, troca de faixa ou nova preparação).
    @discardableResult
    func prepareIncoming(fileB: AVAudioFile, songId: String, plan: TransitionPlan) async -> TransitionPlan? {
        guard !hasStartedIncoming, !hasTriggeredPlayAtFuture else { return nil }
        guard Self.canPlay(file: fileB) else {
            clearPreparedIncoming()
            return nil
        }

        prepareGeneration &+= 1
        let generation = prepareGeneration
        isPreparingIncoming = true
        defer {
            if generation == prepareGeneration { isPreparingIncoming = false }
        }
        let activeSongId = activeDeck.songId

        var effectivePlan = plan
        let now = currentTime(for: activeDeck)
        let durA = activeDeck.fileDuration
        if durA > 0, now >= plan.trackA.mixStartSec - 0.25 {
            let remaining = durA - now
            guard remaining >= 3.5 else {
                clearPreparedIncoming()
                return nil
            }
            // Mesmo se o usuário pulou para depois do mixStart, preserva o beatmatch (targetRateA/initialRateB)
            // e dispara uma entrada rápida em ~1.2 s em vez de cancelar a sincronia de BPM!
            let fadeStart = min(now + 1.2, max(now + 0.35, durA - min(6.0, remaining * 0.65)))
            let fadeEnd = max(fadeStart + 2.5, min(durA - 0.25, fadeStart + max(4.0, plan.mix.durationSec * 0.5)))
            effectivePlan.trackA.rampStartSec = now
            effectivePlan.trackA.mixStartSec = fadeStart
            effectivePlan.trackA.mixEndSec = fadeEnd
            effectivePlan.sync.rampDurationSec = max(0.3, (fadeStart - now) * 0.75)
            effectivePlan.mix.durationSec = fadeEnd - fadeStart
            activeDeck.resetDSPToNeutral()
        }

        let sr = fileB.processingFormat.sampleRate
        let totalDur = Double(fileB.length) / max(sr, 1)
        let urlB = fileB.url

        // Os pontos de mix já chegam no downbeat da grade constante do servidor (análise v2): o app não
        // re-detecta batidas no áudio. Em segundo plano só mede a loudness da Faixa B, se ainda não tiver.
        let measuredLoudnessB: (lufs: Float, peakDB: Float)?
        if volumeCompensation != .off, LoudnessCache.shared.get(songId) == nil {
            measuredLoudnessB = await Task.detached(priority: .userInitiated) { Self.measureLoudness(url: urlB) }.value
        } else {
            measuredLoudnessB = nil
        }

        // Durante a análise o usuário pode ter dado seek, trocado de faixa ou outra preparação pode ter começado
        guard generation == prepareGeneration,
              activeDeck.songId == activeSongId,
              !hasStartedIncoming, !hasTriggeredPlayAtFuture else { return nil }

        if let measured = measuredLoudnessB {
            LoudnessCache.shared.set(songId, lufs: measured.lufs, peakDB: measured.peakDB)
        }

        // Se a medição terminou em cima do ponto de mix, adia a entrada em batidas INTEIRAS de A:
        // a fase entre as grades de A e B continua a mesma (o PLL pela grade faz o ajuste fino).
        let nowAfter = currentTime(for: activeDeck)
        let minLead = 0.35
        if effectivePlan.trackA.mixStartSec - nowAfter < minLead {
            let beatSecA = 60.0 / max(effectivePlan.trackA.bpm, 60.0)
            let needed = minLead - (effectivePlan.trackA.mixStartSec - nowAfter)
            let shift = ceil(needed / beatSecA) * beatSecA
            guard durA <= 0 || effectivePlan.trackA.mixStartSec + shift < durA - 3.0 else {
                clearPreparedIncoming()
                return nil
            }
            effectivePlan.trackA.mixStartSec += shift
            effectivePlan.trackA.mixEndSec += shift
            if durA > 0 {
                effectivePlan.trackA.mixEndSec = min(effectivePlan.trackA.mixEndSec, durA - 0.15)
            }
            effectivePlan.trackA.rampStartSec = min(max(nowAfter, effectivePlan.trackA.rampStartSec), effectivePlan.trackA.mixStartSec)
            effectivePlan.mix.durationSec = max(2.0, effectivePlan.trackA.mixEndSec - effectivePlan.trackA.mixStartSec)
        }

        if effectivePlan.transitionType == "beatmatch" {
            // 2. Adapta a duração da saída de forma inteligente conforme a combinação real das seções (nunca tempo fixo cego!):
            //    - Vocal + Vocal (ex.: chorus/verse -> verse/chorus): 8 compassos se o BPM for rápido (>= 130) ou 6 compassos se lento,
            //      para não embolar dois cantores mas sem jamais encurtar a ponto de parecer corte seco.
            //    - Instrumental / Bridge -> Intro / Beat: permite respirar por 8 a 16 compassos completos conforme o plano da IA!
            //    A duração é sempre um número inteiro de compassos de A (o fim do mix cai no tempo 1 de um compasso).
            let secALow = (effectivePlan.trackA.section ?? "").lowercased()
            let secBLow = (effectivePlan.trackB.section ?? "").lowercased()
            let aHasStrongVocal = secALow.contains("chorus") || secALow.contains("voz")
            let bHasStrongVocal = secBLow.contains("chorus") || secBLow.contains("voz")
            if aHasStrongVocal && bHasStrongVocal, (effectivePlan.mix.bars ?? 8) > 8 {
                let barSec = 4.0 * 60.0 / max(effectivePlan.trackA.bpm, 60.0)
                let targetBars = effectivePlan.trackA.bpm >= 130.0 ? 8 : 6
                let adaptedDur = Double(targetBars) * barSec
                if effectivePlan.trackA.mixEndSec - effectivePlan.trackA.mixStartSec > adaptedDur + 1.0 {
                    effectivePlan.trackA.mixEndSec = min(durA - 0.15, effectivePlan.trackA.mixStartSec + adaptedDur)
                    effectivePlan.mix.bars = targetBars
                    effectivePlan.mix.durationSec = effectivePlan.trackA.mixEndSec - effectivePlan.trackA.mixStartSec
                }
            }

            // 3. Preserva a rampa variável do plano (calculada conforme a combinação das duas faixas:
            //    sobe suavemente o BPM com antecedência e mantém tocando no novo ritmo antes de mixar).
            //    Só adapta a rampa se o usuário já estiver depois de `rampStartSec` (ex.: arrastou a barra).
            let rateDelta = Double(abs(effectivePlan.sync.targetRateA - 1.0))
            if rateDelta >= 0.003,
               nowAfter > effectivePlan.trackA.rampStartSec && nowAfter < effectivePlan.trackA.mixStartSec - 0.25 {
                let avail = effectivePlan.trackA.mixStartSec - nowAfter
                effectivePlan.trackA.rampStartSec = nowAfter
                effectivePlan.sync.rampDurationSec = max(0.35, min(effectivePlan.sync.rampDurationSec, avail * 0.72))
            }

            print(String(format: "[SYNC-LOCK] Plano final | A %.3fs→%.3fs | B %.3fs | Ramp:%.1fs (dur %.1fs) | RateA:%.3fx RateB:%.3fx",
                         effectivePlan.trackA.mixStartSec, effectivePlan.trackA.mixEndSec, effectivePlan.trackB.entrySec,
                         effectivePlan.trackA.rampStartSec, effectivePlan.sync.rampDurationSec,
                         effectivePlan.sync.targetRateA, effectivePlan.sync.initialRateB ?? 1.0))
        }

        let incoming = incomingDeck
        resetDeckNode(incoming)
        activate(incoming)

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
            return nil
        }

        transitionPlan = effectivePlan
        incomingSongId = songId
        if isPlaying {
            ensureRunning()
        }
        return effectivePlan
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
        activate(activeDeck)

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
        scheduleMonitor(every: 1.0 / 20.0)
    }

    private func scheduleMonitor(every interval: TimeInterval) {
        stopMonitoring()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitorTick()
            }
        }
        // Tolerância permite ao sistema agrupar os despertares (economiza energia); nas janelas críticas é mínima
        timer.tolerance = interval > 0.05 ? interval * 0.2 : 0.002
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        monitorInterval = interval
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        monitorInterval = 0
    }

    /// Cadência do monitor conforme o que precisa ser feito:
    /// - 60 Hz só na janela crítica (último segundo antes da entrada de B, durante a mixagem e na recuperação do BPM),
    ///   onde o disparo de B e a automação de volume/EQ/filtro precisam de precisão;
    /// - 20 Hz na aproximação do mix (rampa de BPM da faixa A);
    /// - o resto do tempo, só `uiUpdateInterval` (acompanhar a posição para a tela e detectar o fim da faixa).
    private func desiredMonitorInterval() -> TimeInterval {
        if hasStartedIncoming || hasTriggeredPlayAtFuture || isPreparingIncoming || postTransitionRecoverDuration > 0.05 {
            return 1.0 / 60.0
        }
        let t = lastKnownTime
        let dur = activeDeck.fileDuration
        if let plan = transitionPlan, incomingDeck.file != nil {
            // Mesmo "início seguro" que o tick usa para disparar a Faixa B
            let mixStart = min(plan.trackA.mixStartSec, max(2.0, dur - 2.0))
            if t >= mixStart - 1.2 { return 1.0 / 60.0 }
            if t >= min(plan.trackA.rampStartSec, mixStart) - 9.0 { return 1.0 / 20.0 }
        } else if dur > 1, t >= dur - 1.5 {
            return 1.0 / 30.0
        }
        return max(uiUpdateInterval, 0.1)
    }

    private func resetTransitionState() {
        prepareGeneration &+= 1
        isPreparingIncoming = false
        hasStartedIncoming = false
        hasTriggeredPlayAtFuture = false
        transitionPlan = nil
        incomingSongId = nil
        livePhaseErrorMs = 0
        isPLLCorrecting = false
        lastloggedPLLTime = 0
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
        runMonitorTick()
        // Ajusta a cadência (a menos que o tick tenha parado o monitor, ex.: fim da faixa sem próxima)
        guard monitorTimer != nil else { return }
        let desired = desiredMonitorInterval()
        if abs(desired - monitorInterval) > 0.0005 { scheduleMonitor(every: desired) }
    }

    private func runMonitorTick() {
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
        let nowAbs = CFAbsoluteTimeGetCurrent()
        if nowAbs - lastUIEmit >= uiUpdateInterval {
            lastUIEmit = nowAbs
            onTimeUpdate?(uiTime, uiDeck.fileDuration)
        }

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
        if !hasTriggeredPlayAtFuture && !isPreparingIncoming {
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

        // 3. Fase da Mixagem Completa: Ajustador Automático de Fase em Tempo Real (Beat-Phase Servo PLL a 60 Hz)
        //    + Curva de Volume (Sobrepor) + EQ Central/3-Bandas + Filtros Passa-Alta/Baixa + Reverb
        if hasStartedIncoming {
            let mixDuration = max(safeMixEnd - safeMixStart, 0.5)
            let p = Float(min(max((t - safeMixStart) / mixDuration, 0.0), 1.0))

            if isBeatmatch {
                let bpmA = max(plan.trackA.bpm, 60.0)
                let bpmB = max(plan.trackB.bpm, 60.0)
                let beatSecA = 60.0 / bpmA
                let beatSecB = 60.0 / bpmB
                let tB = incomingLastKnownTime
                let entryB = incomingDeck.segmentStartSec
                let baseRateB = Double(max(plan.sync.initialRateB ?? 1.0, 0.5))
                let wallBeatSecB = beatSecB / baseRateB

                // Erro de fase pela grade: posição sample-accurate de cada deck no próprio arquivo, convertida em
                // batidas com o BPM exato do servidor (grade constante). Não há re-detecção no áudio: o detector de
                // "bumbo" por energia de grave travava no baixo com sidechain (~95 ms depois do bumbo) e desalinhava.
                let beatsElapsedA = (t - safeMixStart) / beatSecA
                let beatsElapsedB = (tB - entryB) / beatSecB
                let rawBeatErr = beatsElapsedA - beatsElapsedB
                let gridBeatErr = rawBeatErr - round(rawBeatErr)
                let gridErrWallSec = gridBeatErr * wallBeatSecB

                // Nos primeiros 380 ms o playerTime do CoreAudio ainda está saindo do preroll: espera estabilizar.
                if t - safeMixStart >= 0.38 {
                    livePhaseErrorMs = gridErrWallSec * 1000.0

                    // Servo proporcional suave (pitch-bend de até ±3.2% no Deck B)
                    let kp = 0.25
                    let nudge = min(max(gridBeatErr * kp, -0.032), 0.032)
                    let correctedRateB = Float(min(max(baseRateB * (1.0 + nudge), 0.88), 1.12))
                    incomingDeck.timePitch.rate = correctedRateB
                    isPLLCorrecting = abs(livePhaseErrorMs) >= 3.0

                    if abs(livePhaseErrorMs) >= 5.0 && (t - lastloggedPLLTime) >= 1.2 {
                        lastloggedPLLTime = t
                        print(String(format: "[AUTO-SYNC PLL] Corrigindo fase pela grade: erro=%+.1fms → RateB=%.4fx (base %.4fx)",
                                     livePhaseErrorMs, correctedRateB, baseRateB))
                    }
                } else {
                    incomingDeck.timePitch.rate = Float(baseRateB)
                    livePhaseErrorMs = 0
                    isPLLCorrecting = false
                }
            } else {
                livePhaseErrorMs = 0
                isPLLCorrecting = false
            }

            applyTransitionDSP(progress: p, plan: plan, outgoing: activeDeck, incoming: incomingDeck, primeOnlyIncoming: false)
        }

        // 4. Fim da transição: promove o Deck B como novo Deck ativo sem interromper o áudio
        if hasStartedIncoming && (t >= safeMixEnd || t >= dur - 0.1) {
            let outgoing = activeDeck
            let incoming = incomingDeck
            // Restaura a taxa base nominal da Faixa B (sem o micro pitch-bend do PLL) antes da rampa de retorno a 1.0x
            let targetBaseRateB = isBeatmatch ? (plan.sync.initialRateB ?? 1.0) : incoming.timePitch.rate
            incoming.timePitch.rate = targetBaseRateB
            let currentRateB = targetBaseRateB

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

    /// Quando (fração do mix, 0…1) a faixa que SAI começa a perder cada coisa. A batida de A (o grave, que carrega o
    /// bumbo) é mantida até a metade do mix: antes o grave saía em 24–34% e o resto só em 62–66%, então a batida de A
    /// sumia cedo e ela ficava só com médios e agudos por boa parte da transição.
    private enum OutgoingHold {
        static let bassSwapCenter: Float = 0.55   // troca de graves A → B
        static let bassSwapWidth: Float = 0.12
        static let midOutStart: Float = 0.72      // médios de A recuam (EQ de 3 bandas)
        static let midOutSpan: Float = 0.26
        static let highOutStart: Float = 0.76     // agudos de A recuam (EQ de 3 bandas)
        static let highOutSpan: Float = 0.22
        static let filterStart: Float = 0.70      // varredura do filtro de saída de A
        static let volumeStart: Float = 0.74      // fade de volume de A na curva "Sobrepor"
    }

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

        // 2. CURVA DE VOLUME
        let volStyle = AutomixVolumeCurve(rawValue: plan.mix.volumeCurve ?? "") ?? .overlap
        let (volA, volB) = computeVolumes(progress: p, curve: volStyle, oneBarFrac: oneBarFrac)
        if !primeOnlyIncoming {
            // Compensação de potência: com A e B em 100% a soma sobe ~3 dB; reduz os dois decks juntos
            // para manter a potência constante (máx. -3 dB). Em p = 0 e p = 1 o fator volta a 1.0 (sem degrau).
            let sumPower = volA * volA + volB * volB
            let overlapTrim: Float = sumPower > 1.0 ? 1.0 / sqrt(sumPower) : 1.0
            outgoing.playerNode.volume = volA * overlapTrim
            incoming.playerNode.volume = volB * overlapTrim
        }

        // 3. ESTILO DE EQ (Troca de Graves após a Faixa B atingir intensidade plena; evita cortar médios/agudos junto com filtro!)
        let eqStyle = AutomixEQStyle(rawValue: plan.mix.eqStyle ?? "") ?? .centerBassSwap
        let cutDb = min(plan.mix.eqSwap.bassCutDb, -20.0)
        let hasOutgoingFilter: Bool = {
            switch filterStyle {
            case .none, .lpIn, .hpIn: return false
            default: return true
            }
        }()
        applyEQ(progress: p, style: eqStyle, cutDb: cutDb, swapCenter: Float(plan.mix.eqSwap.bassSwapAtProgress), hasOutgoingFilter: hasOutgoingFilter, outgoing: outgoing, incoming: incoming, primeOnlyIncoming: primeOnlyIncoming)

        // 4. APLICA FILTROS PASSA-ALTA / PASSA-BAIXA + SAÍDA DE RUÍDO FINAL (WASH-OUT)
        applyFilters(progress: p, style: filterStyle, useReverbTail: useReverbTail, outgoing: outgoing, incoming: incoming, primeOnlyIncoming: primeOnlyIncoming)
    }

    private func computeVolumes(progress p: Float, curve: AutomixVolumeCurve, oneBarFrac: Float) -> (Float, Float) {
        switch curve {
        case .auto, .overlap:
            // SOBREPOR (3 Fases DJ com saída progressiva e musical — NUNCA corte seco no fim!):
            // Fase 1 (0.00..0.22): Faixa B sobe até 100% de potência.
            // Fase 2 (0.22..0.74): AMBAS tocam juntas em 100% de potência (convivência plena das duas faixas).
            // Fase 3 (0.74..1.00): Faixa A desliza suavemente em curva cosseno de 100% até 0% junto com o filtro de saída!
            let vB = p < 0.22 ? sin((p / 0.22) * (.pi / 2.0)) : 1.0
            let vA: Float = p < OutgoingHold.volumeStart
                ? 1.0
                : cos(((p - OutgoingHold.volumeStart) / (1.0 - OutgoingHold.volumeStart)) * (.pi / 2.0))
            return (vA, vB)

        case .smoothCrossfade:
            let vB = p < 0.32 ? sin((p / 0.32) * (.pi / 2.0)) : 1.0
            let vA: Float = p < 0.60 ? 1.0 : cos(((p - 0.60) / 0.40) * (.pi / 2.0))
            return (vA, vB)

        case .fadeInFadeOut:
            let vB = min(p / 0.28, 1.0)
            let vA: Float = p < 0.64 ? 1.0 : max(0.0, 1.0 - ((p - 0.64) / 0.36))
            return (vA, vB)

        case .cutInFadeOut:
            // B entra direta a 100% no Beat 1; A segue firme junto e sai em fade suave no terço final (0.66..1.00)
            let r = min(p / 0.025, 1.0)
            let vA: Float = p < 0.66 ? 1.0 : cos(((p - 0.66) / 0.34) * (.pi / 2.0))
            return (vA, r)

        case .fadeInCutOut:
            // Mesmo no modo "Corte na saída", faz um decaimento musical rápido no último compasso (0.82..1.00)
            // em vez de guilhotinar em 0.97..1.00 para nunca parecer erro ou corte seco abrupto!
            let vB = min(p / 0.25, 1.0)
            let vA: Float = p < 0.82 ? 1.0 : cos(((p - 0.82) / 0.18) * (.pi / 2.0))
            return (vA, vB)

        case .centerCut:
            let vB = p < 0.30 ? min(p / 0.25, 1.0) : 1.0
            let vA: Float = p < 0.50 ? 1.0 : cos(((min(p, 0.68) - 0.50) / 0.18) * (.pi / 2.0)) * (p >= 0.68 ? 0.0 : 1.0)
            return (vA, vB)

        case .crossfadeQuickOut:
            let vB = min(p / 0.25, 1.0)
            let vA: Float = p < 0.65 ? 1.0 : cos(((p - 0.65) / 0.35) * (.pi / 2.0))
            return (vA, vB)

        case .fadeIn1BarCutOut:
            let vB = min(p / oneBarFrac, 1.0)
            let tailFrac = max(0.16, oneBarFrac * 0.85)
            let startOut = 1.0 - tailFrac
            let vA: Float = p < startOut ? 1.0 : cos(((p - startOut) / tailFrac) * (.pi / 2.0))
            return (vA, vB)

        case .overlap1BarCutOut:
            let startB = max(0.0, 1.0 - oneBarFrac)
            let vB: Float = p < startB ? 0.0 : min((p - startB) / 0.025, 1.0)
            let vA: Float = p < 0.84 ? 1.0 : cos(((p - 0.84) / 0.16) * (.pi / 2.0))
            return (vA, vB)
        }
    }

    private func applyEQ(
        progress p: Float,
        style: AutomixEQStyle,
        cutDb: Float,
        swapCenter: Float,
        hasOutgoingFilter: Bool,
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
            // Troca de grave no meio do mix: a batida de A é mantida até lá, e a de B assume em seguida
            applyBassWindow(center: OutgoingHold.bassSwapCenter, width: OutgoingHold.bassSwapWidth)

        case .startBassSwap:
            applyBassWindow(center: 0.38, width: 0.10)

        case .endBassSwap:
            applyBassWindow(center: 0.65, width: 0.12)

        case .quickBassCut:
            applyBassWindow(center: OutgoingHold.bassSwapCenter, width: 0.03)

        case .longBassCut:
            applyBassWindow(center: 0.55, width: 0.40)

        case .bassFadeOut:
            let sA = min(max((p - 0.20) / 0.50, 0.0), 1.0)
            let sB = min(max((p - 0.35) / 0.35, 0.0), 1.0)
            if !primeOnlyIncoming {
                outBands[0].gain = cutDb * sA
                outBands[1].gain = 0.0
                outBands[2].gain = 0.0
            }
            inBands[0].gain = cutDb * (1.0 - sB)
            inBands[1].gain = 0.0
            inBands[2].gain = 0.0

        case .threeBandTransition:
            // Transição de 3 Bandas (3 Fases DJ):
            // 1º (0.00..0.49): Médios e agudos da B entram cedo; a A segue inteira, com a batida (grave) dela.
            // 2º (0.49..0.61): Troca de grave: a batida de A passa para a de B.
            // 3º (0.72..1.00): Médios e agudos da A recuam junto com o filtro de saída e o fade de volume.
            let bassLo = OutgoingHold.bassSwapCenter - OutgoingHold.bassSwapWidth / 2
            let lowS = min(max((p - bassLo) / OutgoingHold.bassSwapWidth, 0.0), 1.0)
            let midInS = min(max((p - 0.06) / 0.22, 0.0), 1.0)
            let midOutS = min(max((p - OutgoingHold.midOutStart) / OutgoingHold.midOutSpan, 0.0), 1.0)
            let highInS = min(max(p / 0.16, 0.0), 1.0)
            let highOutS = min(max((p - OutgoingHold.highOutStart) / OutgoingHold.highOutSpan, 0.0), 1.0)

            let midCutIn: Float = -10.0
            let highCutIn: Float = -8.0
            let midCutOut: Float = hasOutgoingFilter ? -11.0 : -15.0
            let highCutOut: Float = hasOutgoingFilter ? -9.0 : -13.0

            if !primeOnlyIncoming {
                outBands[0].gain = cutDb * lowS
                outBands[1].gain = midCutOut * midOutS
                outBands[2].gain = highCutOut * highOutS
            }
            inBands[0].gain = cutDb * (1.0 - lowS)
            inBands[1].gain = midCutIn * (1.0 - midInS)
            inBands[2].gain = highCutIn * (1.0 - highInS)
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

        // Fase 1 (0.00..0.24): filtro de entrada da B abre completamente cedo para ela já tocar em potência total!
        let inSweep = min(max(p / 0.24, 0.0), 1.0)
        // Fase 2 (0.24..0.70): AMBAS tocam juntas sem filtro na A (convivência plena das duas faixas)!
        // Fase 3 (0.70..1.00): filtro de saída da Faixa A varre junto com o decaimento de volume.
        let outSweep = min(max((p - OutgoingHold.filterStart) / (1.0 - OutgoingHold.filterStart), 0.0), 1.0)

        switch style {
        case .none:
            break

        case .lpOut:
            // Passa-baixa na saída (abafa a Faixa A de 18 kHz até 280 Hz na saída)
            outLP = expFreq(from: 18_000, to: 280, t: outSweep)

        case .lpIn:
            // Passa-baixa na entrada (Faixa B surge de 380 Hz abrindo até 18 kHz antes do meio)
            inLP = expFreq(from: 380, to: 18_000, t: inSweep)

        case .lpInLpOut:
            inLP = expFreq(from: 380, to: 18_000, t: inSweep)
            outLP = expFreq(from: 18_000, to: 280, t: outSweep)

        case .lpInHpOut:
            inLP = expFreq(from: 380, to: 18_000, t: inSweep)
            outHP = expFreq(from: 25, to: 2_600, t: outSweep)

        case .hpOut:
            // Passa-alta na saída (afina de 25 Hz até 2600 Hz enquanto o volume desce no terço final)
            outHP = expFreq(from: 25, to: 2_600, t: outSweep)

        case .hpIn:
            // Passa-alta na entrada (Faixa B entra limpa em 1100 Hz e desce até 20 Hz antes do meio)
            inHP = expFreq(from: 1_100, to: 20, t: inSweep)

        case .auto, .hpInHpOut:
            inHP = expFreq(from: 1_000, to: 20, t: inSweep)
            outHP = expFreq(from: 25, to: 2_600, t: outSweep)

        case .hpInLpOut:
            inHP = expFreq(from: 1_000, to: 20, t: inSweep)
            outLP = expFreq(from: 18_000, to: 280, t: outSweep)

        case .partialHpOut:
            // Passa-alta parcial na saída: sobe até 1650 Hz (antes parava em 680 Hz e deixava toda a voz/caixa alta!)
            outHP = expFreq(from: 25, to: 1_650, t: outSweep)

        case .finalNoiseOut:
            // Saída de ruído final / Wash-out (High-Pass até 2.8 kHz + cauda espacial de Reverb Hall)
            outHP = expFreq(from: 25, to: 2_800, t: outSweep)
            inHP = expFreq(from: 800, to: 20, t: inSweep)
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
                if outgoing.reverb.bypass { outgoing.reverb.bypass = false }
                outgoing.reverb.wetDryMix = revProgress * 58.0
            } else {
                outgoing.reverb.wetDryMix = 0.0
                if !outgoing.reverb.bypass { outgoing.reverb.bypass = true }
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
        if !incoming.reverb.bypass { incoming.reverb.bypass = true }
    }
}
