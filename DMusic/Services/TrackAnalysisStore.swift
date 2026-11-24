import Foundation
import AVFoundation
import Accelerate
import Observation

nonisolated struct TrackMixMetadata: Codable, Hashable, Sendable {
    let songId: String
    let bpm: Int
    var preciseBPM: Double?  // BPM com precisão decimal (ex.: 123.8) para evitar drift no beatmap
    var beatOffset: Double?  // Fase global da grade de batidas em segundos (0 ..< 60/BPM)
    let camelot: String      // Ex.: "8A", "8B", "11A"
    let musicalKey: String   // Ex.: "Am", "C", "F#m"
    var energy: Double?      // Energia 0.0 ... 1.0
    var analyzer: String?    // "allin1" (servidor) ou "local"
    let cueIn: Double        // Segundos exatos do 1º beat real na grade
    let cueOut: Double       // Segundos exatos de um beat na grade onde a virada deve começar
    var vibe: [Float]? = nil // Vetor acústico/timbral/rítmico 24D (Z-score + L2) para similaridade de emoção/estilo

    var effectiveBPM: Double {
        preciseBPM ?? Double(bpm)
    }

    var beatPeriod: Double {
        60.0 / max(effectiveBPM, 60.0)
    }

    var effectiveBeatOffset: Double {
        beatOffset ?? cueIn.truncatingRemainder(dividingBy: beatPeriod)
    }

    var formattedBPM: String {
        let val = effectiveBPM
        if abs(val - val.rounded()) < 0.05 {
            return String(format: "%.0f", val.rounded())
        }
        return String(format: "%.1f", val)
    }

    var badgeText: String {
        "\(formattedBPM) BPM • \(camelot)"
    }
}

/// Analisa arquivos de áudio locais (Downloads e Cache de Recentes) usando `Accelerate / vDSP`,
/// construindo o Beatmap real (BPM decimal + Fase da grade de batidas `beatOffset` + Cue-In/Cue-Out cravados no beat)
/// e a Tonalidade na Roda de Camelot (1A–12B).
@Observable
@MainActor
final class TrackAnalysisStore {
    private(set) var items: [String: TrackMixMetadata] = [:]
    private(set) var serverHealth: MixServerHealth?
    private(set) var isSyncingServer = false
    private(set) var lastServerSyncAt: Date?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let fileURL: URL

    /// Versão atual do algoritmo de beatmap (re-analisa entradas antigas que não tinham `beatOffset` e `preciseBPM`).
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("track_mix_analysis.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: TrackMixMetadata].self, from: data) {
            // Mantém análises válidas (do servidor `allin1` ou locais com beatOffset)
            items = decoded.filter { $0.value.analyzer == "allin1" || ($0.value.beatOffset != nil && $0.value.preciseBPM != nil) }
        }
    }

    func metadata(for songId: String) -> TrackMixMetadata? {
        items[songId]
    }

    /// Baixa em lote os metadados pré-calculados no servidor (`allin1` + `librosa`), sobrescrevendo análises locais.
    func syncFromServer(mixClient: MixServerClient) async {
        guard !isSyncingServer else { return }
        isSyncingServer = true
        defer { isSyncingServer = false }

        do {
            async let h = mixClient.health()
            async let list = mixClient.fetchAllTracks()
            let (healthInfo, tracks) = try await (h, list)
            serverHealth = healthInfo

            var updated = false
            for t in tracks {
                let meta = TrackMixMetadata(
                    songId: t.id,
                    bpm: Int(t.bpm.rounded()),
                    preciseBPM: t.bpm,
                    beatOffset: t.mixInSec.truncatingRemainder(dividingBy: 60.0 / max(t.bpm, 60.0)),
                    camelot: t.camelot,
                    musicalKey: t.musicalKey ?? "",
                    energy: t.energy,
                    analyzer: t.analyzer ?? "allin1",
                    cueIn: t.mixInSec,
                    cueOut: t.mixOutSec,
                    vibe: (t.vibe?.isEmpty == false) ? t.vibe : nil
                )
                if items[t.id] != meta {
                    items[t.id] = meta
                    updated = true
                }
            }
            if updated { save() }
            lastServerSyncAt = Date()
        } catch {
            if let h = try? await mixClient.health() {
                serverHealth = h
            } else {
                serverHealth = nil
            }
        }
    }

    /// Atualiza silenciosamente os metadados caso o último sync com o servidor `allin1` tenha mais de `maxAgeSec`.
    func syncFromServerIfStale(mixClient: MixServerClient?, maxAgeSec: TimeInterval = 600) async {
        guard let mixClient else { return }
        if let last = lastServerSyncAt, Date().timeIntervalSince(last) < maxAgeSec { return }
        await syncFromServer(mixClient: mixClient)
    }

    func refreshHealth(mixClient: MixServerClient) async {
        serverHealth = try? await mixClient.health()
    }

    private struct AnalysisJob {
        let songId: String
        let url: URL
        let onComplete: (@MainActor () -> Void)?
    }
    @ObservationIgnored private var pendingJobs: [AnalysisJob] = []
    @ObservationIgnored private var isAnalyzing = false
    private static let failedIdsKey = "analysis_failed_ids"
    /// Faixas que a análise local não conseguiu ler: não tenta de novo a cada abertura do app.
    @ObservationIgnored private lazy var failedIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Self.failedIdsKey) ?? [])

    /// Analisa em background um arquivo local caso a música ainda não possua Beatmap + Camelot salvos.
    /// A análise local (DSP no aparelho) é cara: roda uma faixa por vez, em prioridade mínima, e fica parada no
    /// Modo Pouca Energia (o servidor já analisou quase toda a biblioteca).
    func analyzeIfNeeded(songId: String, localURL: URL?, onComplete: (@MainActor () -> Void)? = nil) {
        if items[songId] != nil {
            onComplete?()
            return
        }
        guard !inFlight.contains(songId), !failedIds.contains(songId), let localURL,
              FileManager.default.fileExists(atPath: localURL.path),
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        inFlight.insert(songId)
        pendingJobs.append(AnalysisJob(songId: songId, url: localURL, onComplete: onComplete))
        drainAnalysisQueue()
    }

    private func drainAnalysisQueue() {
        guard !isAnalyzing, !pendingJobs.isEmpty else { return }
        isAnalyzing = true
        let job = pendingJobs.removeFirst()
        Task { [weak self] in
            let songId = job.songId
            let url = job.url
            let result = await Task.detached(priority: .background) {
                Self.extractMixMetadata(songId: songId, url: url)
            }.value
            guard let self else { return }
            self.inFlight.remove(songId)
            self.isAnalyzing = false
            if let result {
                self.items[songId] = result
                self.save()
                job.onComplete?()
            } else {
                self.failedIds.insert(songId)
                UserDefaults.standard.set(Array(self.failedIds), forKey: Self.failedIdsKey)
            }
            self.drainAnalysisQueue()
        }
    }

    func ensureAnalyzed(songId: String, localURL: URL?) async -> TrackMixMetadata? {
        if let existing = items[songId] { return existing }
        guard let localURL, FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        let result = await Task.detached(priority: .userInitiated) {
            Self.extractMixMetadata(songId: songId, url: localURL)
        }.value
        if let result {
            items[songId] = result
            save()
        }
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Ordenação Harmônica e Seleção da Melhor Próxima Música (Beatmap + Camelot)

    /// Escolhe na fila o índice da música mais compatível em BPM e Tom Camelot com a faixa atual `anchor`.
    func bestMatchingUpcomingIndex(for anchor: Song, in queue: [Song], from startIndex: Int) -> Int? {
        guard startIndex < queue.count, let anchorMeta = items[anchor.id] else { return nil }
        var bestIdx: Int?
        var bestScore = -Double.infinity

        let searchLimit = min(queue.count, startIndex + 40)
        for idx in startIndex..<searchLimit {
            guard let candMeta = items[queue[idx].id] else { continue }
            let score = Self.transitionCompatibilityScore(from: anchorMeta, to: candMeta)
            if score > bestScore {
                bestScore = score
                bestIdx = idx
            }
        }
        return bestIdx
    }

    /// Organiza as músicas priorizando transições suaves de BPM e compatibilidade harmônica na Roda de Camelot.
    func orderByHarmonicFlow(_ songs: [Song], startingWith first: Song? = nil) -> [Song] {
        guard songs.count > 2 else { return songs.shuffled() }
        var pool = songs.shuffled()
        var ordered: [Song] = []
        ordered.reserveCapacity(songs.count)

        if let first {
            if let idx = pool.firstIndex(where: { $0.id == first.id }) {
                ordered.append(pool.remove(at: idx))
            } else {
                ordered.append(first)
            }
        } else if let firstAnalyzed = pool.firstIndex(where: { items[$0.id] != nil }) {
            ordered.append(pool.remove(at: firstAnalyzed))
        } else {
            ordered.append(pool.removeFirst())
        }

        while !pool.isEmpty {
            let current = ordered.last!
            guard let curMeta = items[current.id] else {
                if let nextAnalyzedIdx = pool.firstIndex(where: { items[$0.id] != nil }) {
                    ordered.append(pool.remove(at: nextAnalyzedIdx))
                } else {
                    ordered.append(pool.removeFirst())
                }
                continue
            }

            // Procura entre todas as analisadas disponíveis a melhor combinação real de BPM + Camelot
            var bestIdx = 0
            var bestScore = -Double.infinity

            for i in 0..<pool.count {
                let candidate = pool[i]
                if let candMeta = items[candidate.id] {
                    // Pequeno jitter aleatório (0..1.5) apenas para desempatar músicas com mesmo BPM e Camelot
                    let score = Self.transitionCompatibilityScore(from: curMeta, to: candMeta) + Double.random(in: 0...1.5)
                    if score > bestScore {
                        bestScore = score
                        bestIdx = i
                    }
                }
            }

            if bestScore == -Double.infinity {
                ordered.append(pool.removeFirst())
            } else {
                ordered.append(pool.remove(at: bestIdx))
            }
        }

        return ordered
    }

    /// Calcula pontuação de compatibilidade entre duas faixas (prioriza fortemente BPM próximo + vizinhança Camelot).
    nonisolated static func transitionCompatibilityScore(from a: TrackMixMetadata, to b: TrackMixMetadata) -> Double {
        let bpmDiff = effectiveBPMDifference(a.effectiveBPM, b.effectiveBPM)
        // Diferença > 14% de BPM recebe penalidade forte para evitar misturar gêneros/ritmos incompatíveis
        let pctDiff = (bpmDiff / max(a.effectiveBPM, 60.0)) * 100.0
        let bpmPenalty = pctDiff <= 10.0 ? (pctDiff * 3.2) : (32.0 + (pctDiff - 10.0) * 8.0)

        let camDist = camelotDistance(a.camelot, b.camelot)
        let harmonicBonus: Double
        switch camDist {
        case 0: harmonicBonus = 40.0   // Mesma tonalidade (ex.: 8A -> 8A)
        case 1: harmonicBonus = 34.0   // Vizinho harmônico perfeito (ex.: 8A -> 7A, 9A ou 8B)
        case 2: harmonicBonus = 14.0   // Mudança de energia compatível (±2 na roda)
        default: harmonicBonus = -15.0 // Choque tonal
        }

        var score = harmonicBonus - bpmPenalty
        if let cos = SmartShuffler.vibeCosine(a.vibe, b.vibe) {
            // Recompensa fortemente mesma vibe/timbre e penaliza choques de estilo (ex.: piano house -> funk pesado)
            score += cos * 38.0
            if cos < 0.15 { score -= 18.0 }
        }
        return score
    }

    nonisolated static func effectiveBPMDifference(_ bpmA: Double, _ bpmB: Double) -> Double {
        let direct = abs(bpmA - bpmB)
        let doubleTime = abs(bpmA - (bpmB * 2.0))
        let halfTime = abs((bpmA * 2.0) - bpmB)
        return min(direct, min(doubleTime, halfTime))
    }

    /// Calcula o `rate` exato para a próxima música ter o MESMO período de batida da música atual.
    nonisolated static func matchedInitialRate(fromBPM currentBPM: Double, toBPM nextBPM: Double) -> Float {
        guard currentBPM > 40, nextBPM > 40 else { return 1.0 }
        var targetRatio = currentBPM / nextBPM
        if targetRatio > 1.45 {
            targetRatio = (currentBPM * 0.5) / nextBPM
        } else if targetRatio < 0.68 {
            targetRatio = (currentBPM * 2.0) / nextBPM
        }
        // Permite ajuste de até ±16% com algoritmo espectral
        guard targetRatio >= 0.84 && targetRatio <= 1.16 else { return 1.0 }
        return Float(min(max(targetRatio, 0.84), 1.16))
    }

    /// Calcula o erro de fase entre os beats da faixa A e da faixa B no instante atual, no intervalo `[-0.5, +0.5]` beats.
    /// Valor positivo significa que a faixa B está atrasada em relação ao beat da faixa A e precisa acelerar levemente.
    nonisolated static func beatPhaseError(
        timeA: Double,
        metaA: TrackMixMetadata,
        timeB: Double,
        metaB: TrackMixMetadata
    ) -> Double {
        let periodA = metaA.beatPeriod
        let periodB = metaB.beatPeriod
        guard periodA > 0.2, periodB > 0.2 else { return 0 }

        var phaseA = ((timeA - metaA.effectiveBeatOffset) / periodA).truncatingRemainder(dividingBy: 1.0)
        if phaseA < 0 { phaseA += 1.0 }

        var phaseB = ((timeB - metaB.effectiveBeatOffset) / periodB).truncatingRemainder(dividingBy: 1.0)
        if phaseB < 0 { phaseB += 1.0 }

        var diff = phaseA - phaseB
        while diff > 0.5 { diff -= 1.0 }
        while diff < -0.5 { diff += 1.0 }
        return diff
    }

    /// Retorna o próximo instante de batida na grade da faixa `meta` a partir de `afterTime`.
    nonisolated static func nextBeatTimestamp(after afterTime: Double, meta: TrackMixMetadata) -> Double {
        let period = meta.beatPeriod
        let offset = meta.effectiveBeatOffset
        guard period > 0.2 else { return afterTime }
        let beatsElapsed = ceil((afterTime - offset) / period)
        return offset + max(0, beatsElapsed) * period
    }

    nonisolated static func camelotDistance(_ c1: String, _ c2: String) -> Int {
        guard let p1 = parseCamelot(c1), let p2 = parseCamelot(c2) else { return 6 }
        if p1.number == p2.number && p1.letter == p2.letter { return 0 }
        let rawDiff = abs(p1.number - p2.number)
        let wheelStep = min(rawDiff, 12 - rawDiff)
        if p1.letter == p2.letter {
            return wheelStep
        } else if wheelStep == 0 {
            return 1
        } else {
            return wheelStep + 1
        }
    }

    nonisolated private static func parseCamelot(_ code: String) -> (number: Int, letter: Character)? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let letter = trimmed.last, (letter == "A" || letter == "B"),
              let num = Int(trimmed.dropLast()), (1...12).contains(num) else { return nil }
        return (num, letter)
    }

    // MARK: - DSP: Beatmapping (BPM Decimal + Fase do Beat + Cue-In/Cue-Out na Grade) & Camelot Key

    nonisolated private static func extractMixMetadata(songId: String, url: URL) -> TrackMixMetadata? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = Int(file.length)
        let format = file.processingFormat
        let sr = format.sampleRate
        guard sr > 8000, totalFrames > Int(sr * 15) else { return nil }
        let totalDuration = Double(totalFrames) / sr

        // 1. Análise central (24 s) para extrair BPM preciso, fase global das batidas (beatOffset) e Tom Camelot
        let midScanSec = min(24.0, totalDuration * 0.55)
        let midFrames = Int(sr * midScanSec)
        let midStartFrame = max(0, (totalFrames / 2) - (midFrames / 2))
        let midStartSec = Double(midStartFrame) / sr

        var preciseBPM = 120.0
        var beatOffset = 0.0
        var camelotCode = "8A"
        var keyName = "Am"

        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(midFrames)) {
            file.framePosition = AVAudioFramePosition(midStartFrame)
            if (try? file.read(into: buf, frameCount: AVAudioFrameCount(midFrames))) != nil,
               let ch = buf.floatChannelData?[0], buf.frameLength > 4096 {
                let nFrames = Int(buf.frameLength)
                (preciseBPM, beatOffset) = detectBeatGrid(
                    samples: ch,
                    count: nFrames,
                    sampleRate: sr,
                    regionStartSeconds: midStartSec
                )
                (camelotCode, keyName) = detectCamelotKey(samples: ch, count: nFrames, sampleRate: sr)
            }
        }

        let period = 60.0 / max(preciseBPM, 60.0)

        // 2. Detecção do 1º Beat real (Cue-In) nos primeiros 18 s e alinhamento exato com a grade de batidas!
        let introScanSec = min(18.0, totalDuration * 0.25)
        let introFrames = Int(sr * introScanSec)
        var rawCueIn: Double = 0.0
        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(introFrames)) {
            file.framePosition = 0
            if (try? file.read(into: buf, frameCount: AVAudioFrameCount(introFrames))) != nil,
               let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                let win = max(128, Int(sr * 0.01)) // Resolução de 10 ms para achar o ataque do 1º bumbo
                let count = Int(buf.frameLength) / win
                if count > 8 {
                    var rmsList = [Float](repeating: 0, count: count)
                    var peakRMS: Float = 0.0001
                    for i in 0..<count {
                        var r: Float = 0
                        vDSP_rmsqv(ch.advanced(by: i * win), 1, &r, vDSP_Length(win))
                        rmsList[i] = r
                        if r > peakRMS { peakRMS = r }
                    }
                    // Procura o primeiro impacto rítmico forte (>= 22% do pico da introdução)
                    let threshold = max(peakRMS * 0.22, 0.012)
                    for i in 1..<count {
                        if rmsList[i] >= threshold && rmsList[i] > rmsList[i - 1] * 1.15 {
                            rawCueIn = Double(i * win) / sr
                            break
                        }
                    }
                }
            }
        }

        // Crava o cueIn exatamente na batida da grade mais próxima a partir de rawCueIn
        let cueInBeatIndex = max(0, round((rawCueIn - beatOffset) / period))
        let snappedCueIn = max(0, beatOffset + cueInBeatIndex * period)

        // 3. Detecção do Cue-Out (nos últimos 30 s) e alinhamento a um compasso de 4 batidas na grade!
        let outroScanSec = min(30.0, totalDuration * 0.32)
        let outroFrames = Int(sr * outroScanSec)
        var rawCueOut: Double = max(totalDuration - 3.0, snappedCueIn + 12.0)
        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outroFrames)) {
            let startFrame = max(0, totalFrames - outroFrames)
            file.framePosition = AVAudioFramePosition(startFrame)
            if (try? file.read(into: buf, frameCount: AVAudioFrameCount(outroFrames))) != nil,
               let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                let win = max(512, Int(sr * 0.05))
                let count = Int(buf.frameLength) / win
                if count > 4 {
                    var rmsList = [Float](repeating: 0, count: count)
                    var peakRMS: Float = 0.0001
                    for i in 0..<count {
                        var r: Float = 0
                        vDSP_rmsqv(ch.advanced(by: i * win), 1, &r, vDSP_Length(win))
                        rmsList[i] = r
                        if r > peakRMS { peakRMS = r }
                    }
                    let threshold = max(peakRMS * 0.22, 0.012)
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if rmsList[i] >= threshold {
                            rawCueOut = Double(startFrame + (i + 1) * win) / sr
                            break
                        }
                    }
                }
            }
        }

        let cueOutBeatIndex = max(cueInBeatIndex + 16, floor((rawCueOut - beatOffset) / period))
        let snappedCueOut = min(totalDuration - 0.5, max(snappedCueIn + 12.0, beatOffset + cueOutBeatIndex * period))

        return TrackMixMetadata(
            songId: songId,
            bpm: Int(preciseBPM.rounded()),
            preciseBPM: (preciseBPM * 100).rounded() / 100,
            beatOffset: (beatOffset * 1000).rounded() / 1000,
            camelot: camelotCode,
            musicalKey: keyName,
            energy: 0.5,
            analyzer: "local",
            cueIn: (snappedCueIn * 1000).rounded() / 1000,
            cueOut: (snappedCueOut * 1000).rounded() / 1000
        )
    }

    /// Extrai BPM decimal (com interpolação parabólica) e Fase Global das Batidas (`beatOffset`)
    /// enfatizando o bumbo/grave (< 180 Hz) + transientes de percussão a 200 Hz (5 ms de resolução).
    nonisolated private static func detectBeatGrid(
        samples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double,
        regionStartSeconds: Double
    ) -> (bpm: Double, beatOffset: Double) {
        let envRate = 200.0 // 200 Hz = resolução temporal de 5 ms
        let hop = max(64, Int((sampleRate / envRate).rounded()))
        let actualEnvRate = sampleRate / Double(hop)
        let nEnv = count / hop
        guard nEnv > 240 else { return (120.0, 0.0) }

        // Filtro passa-baixa de 1 polo (~170 Hz) para isolar o bumbo (kick drum) + energia total para caixa/hi-hat
        let alpha = Float(min(max((2.0 * Double.pi * 170.0) / sampleRate, 0.005), 0.25))
        var lpState: Float = 0
        var bassEnv = [Float](repeating: 0, count: nEnv)
        var fullEnv = [Float](repeating: 0, count: nEnv)

        for i in 0..<nEnv {
            let base = i * hop
            var bassSqSum: Float = 0
            var fullSqSum: Float = 0
            for j in 0..<hop {
                let x = samples[base + j]
                lpState += alpha * (x - lpState)
                bassSqSum += lpState * lpState
                fullSqSum += x * x
            }
            bassEnv[i] = sqrt(bassSqSum / Float(hop))
            fullEnv[i] = sqrt(fullSqSum / Float(hop))
        }

        // Onset Flux ponderado (75% impacto do bumbo grave + 25% ataque percussivo geral)
        var flux = [Float](repeating: 0, count: nEnv)
        for i in 1..<nEnv {
            let dBass = max(0, bassEnv[i] - bassEnv[i - 1])
            let dFull = max(0, fullEnv[i] - fullEnv[i - 1])
            flux[i] = (dBass * 0.75) + (dFull * 0.25)
        }

        let minBPM = 78.0
        let maxBPM = 162.0
        let minLag = max(2, Int((60.0 / maxBPM) * actualEnvRate))
        let maxLag = min(nEnv / 3, Int((60.0 / minBPM) * actualEnvRate))
        guard maxLag > minLag + 2 else { return (120.0, 0.0) }

        var corr = [Float](repeating: 0, count: maxLag + 2)
        var bestLag = minLag
        var bestScore: Float = -1

        flux.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for lag in minLag...(maxLag + 1) {
                let len = nEnv - lag
                var dot1: Float = 0
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &dot1, vDSP_Length(len))
                var score = dot1 / Float(len)

                if lag * 2 < nEnv {
                    var dot2: Float = 0
                    let len2 = nEnv - lag * 2
                    vDSP_dotpr(base, 1, base.advanced(by: lag * 2), 1, &dot2, vDSP_Length(len2))
                    score += 0.45 * (dot2 / Float(len2))
                }
                corr[lag] = score
                if lag <= maxLag && score > bestScore {
                    bestScore = score
                    bestLag = lag
                }
            }
        }

        // Interpolação parabólica nos vizinhos (bestLag - 1, bestLag, bestLag + 1) para precisão de centésimos de BPM
        var refinedLag = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let y1 = Double(corr[bestLag - 1])
            let y2 = Double(corr[bestLag])
            let y3 = Double(corr[bestLag + 1])
            let denom = (y1 - 2.0 * y2 + y3)
            if abs(denom) > 1e-9 {
                let delta = 0.5 * (y1 - y3) / denom
                if abs(delta) < 1.0 {
                    refinedLag += delta
                }
            }
        }

        let detectedBPM = min(max((60.0 * actualEnvRate) / refinedLag, 75.0), 165.0)
        let periodSec = 60.0 / detectedBPM
        let periodFrames = max(4, Int(refinedLag.rounded()))

        // Histograma de fase (Comb filter) para achar o instante exato dos bumbos na grade (beatOffset)
        var phaseHist = [Float](repeating: 0, count: periodFrames)
        for i in 0..<nEnv {
            let bin = i % periodFrames
            phaseHist[bin] += flux[i]
        }

        // Suaviza o histograma de fase em janela de ±1 frame e encontra o pico do bumbo
        var bestBin = 0
        var bestBinEnergy: Float = -1
        for b in 0..<periodFrames {
            let prev = phaseHist[(b - 1 + periodFrames) % periodFrames]
            let cur = phaseHist[b]
            let next = phaseHist[(b + 1) % periodFrames]
            let energy = prev * 0.25 + cur * 0.5 + next * 0.25
            if energy > bestBinEnergy {
                bestBinEnergy = energy
                bestBin = b
            }
        }

        let localBeatPhaseSec = Double(bestBin) / actualEnvRate
        let absoluteBeatSec = regionStartSeconds + localBeatPhaseSec
        var globalOffset = absoluteBeatSec.truncatingRemainder(dividingBy: periodSec)
        if globalOffset < 0 { globalOffset += periodSec }

        return (detectedBPM, globalOffset)
    }

    /// Detecta a Tonalidade Musical e o código Camelot (1A–12B) via perfil cromático de 12 notas (Goertzel/Chroma + Krumhansl-Schmuckler).
    nonisolated private static func detectCamelotKey(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> (camelot: String, key: String) {
        let decim = max(1, Int(sampleRate / 11025.0))
        let effSR = sampleRate / Double(decim)
        let maxSamples = min(count / decim, Int(effSR * 10.0))
        guard maxSamples > 1024 else { return ("8A", "Am") }

        var downsampled = [Float](repeating: 0, count: maxSamples)
        for i in 0..<maxSamples {
            downsampled[i] = samples[i * decim]
        }

        var chroma = [Double](repeating: 0, count: 12)
        let windowSize = min(4096, maxSamples)
        let step = max(windowSize, maxSamples / 6)

        for pitchClass in 0..<12 {
            var energySum = 0.0
            for octave in 2...5 {
                let midi = 12 * (octave + 1) + pitchClass
                let freq = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
                guard freq < effSR * 0.45 else { continue }
                let k = Int(0.5 + (Double(windowSize) * freq / effSR))
                let omega = (2.0 * Double.pi * Double(k)) / Double(windowSize)
                let coeff = 2.0 * cos(omega)

                var start = 0
                while start + windowSize <= maxSamples {
                    var s1 = 0.0
                    var s2 = 0.0
                    for n in 0..<windowSize {
                        let s = Double(downsampled[start + n]) + coeff * s1 - s2
                        s2 = s1
                        s1 = s
                    }
                    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
                    energySum += max(0, power)
                    start += step
                }
            }
            chroma[pitchClass] = sqrt(energySum)
        }

        let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

        let majorCamelot = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
        let minorCamelot = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]
        let majorNames   = ["C",  "Db", "D",   "Eb", "E",   "F",  "F#", "G",  "Ab", "A",   "Bb", "B"]
        let minorNames   = ["Cm", "C#m","Dm",  "Ebm","Em",  "Fm", "F#m","Gm", "Abm","Am",  "Bbm","Bm"]

        var bestScore = -Double.infinity
        var bestCamelot = "8A"
        var bestKey = "Am"

        for root in 0..<12 {
            var majCorr = 0.0
            var minCorr = 0.0
            for i in 0..<12 {
                let cVal = chroma[(root + i) % 12]
                majCorr += cVal * majorProfile[i]
                minCorr += cVal * minorProfile[i]
            }
            if majCorr > bestScore {
                bestScore = majCorr
                bestCamelot = majorCamelot[root]
                bestKey = majorNames[root]
            }
            if minCorr > bestScore {
                bestScore = minCorr
                bestCamelot = minorCamelot[root]
                bestKey = minorNames[root]
            }
        }

        return (bestCamelot, bestKey)
    }
}
