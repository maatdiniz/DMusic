import Foundation

/// Algoritmo Smart Shuffle e cálculo de compatibilidade (BPM + Vibe/Timbre + Roda de Camelot + Energia)
/// seguindo pontuação 0–100 e multi-start com limite de tempo.
nonisolated enum SmartShuffler {
    struct TrackMeta: Sendable {
        let id: String
        let bpm: Double
        let camelot: CamelotKey
        let energy: Double // 0.0 a 1.0
        let vibe: [Float]? // Vetor 24D Z-score L2 (timbre, bandas, harmonia/percussão, groove)
        let genre: String? // Gênero normalizado (Navidrome) para desempate sutil
    }

    struct ScoreBreakdown: Sendable {
        let bpmPoints: Double
        let camelotPoints: Double
        let energyPoints: Double
        let vibePoints: Double
        let vibeSimilarity: Double?
        let total: Double
    }

    /// Cosseno entre dois vetores de vibe L2-normalizados (`-1.0 ... +1.0`).
    static func vibeCosine(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return nil }
        var dot: Double = 0
        for i in 0..<a.count {
            dot += Double(a[i]) * Double(b[i])
        }
        return min(1.0, max(-1.0, dot))
    }

    /// Calcula pontuação detalhada de 0 a 100 entre duas faixas (com consciência de Vibe/Emoção).
    static func scoreBreakdown(from a: TrackMeta, to b: TrackMeta) -> ScoreBreakdown {
        let hasVibe = (a.vibe?.isEmpty == false) && (b.vibe?.isEmpty == false) && a.vibe?.count == b.vibe?.count
        let sameGenre: Bool = {
            guard let ga = a.genre, let gb = b.genre, !ga.isEmpty, !gb.isEmpty else { return false }
            return ga == gb
        }()

        if hasVibe, let cos = vibeCosine(a.vibe, b.vibe) {
            // Modo Vibe-Aware (total 100 pts):
            //   BPM: 36 pts | Vibe/Clima/Timbre: 36 pts | Camelot: 20 pts | Energia: 8 pts
            let bpmPts = bpmScore(bpmA: a.bpm, bpmB: b.bpm) * (36.0 / 50.0)
            let camPts = camelotScore(keyA: a.camelot, keyB: b.camelot) * (20.0 / 35.0)
            let engPts = energyScore(energyA: a.energy, energyB: b.energy) * (8.0 / 15.0)

            // Mapeia cosseno [-0.20 ... +0.92] -> [0 ... 1] com curva que premia fortemente mesma atmosfera/timbre
            let simNorm = min(1.0, max(0.0, (cos + 0.20) / 1.12))
            var vibePts = 36.0 * pow(simNorm, 1.40)
            // Penalidade forte de choque de clima quando duas faixas pertencem a universos sonoros opostos
            if cos < 0.20 {
                let clash = min(1.0, (0.20 - cos) / 0.50)
                vibePts -= 24.0 * clash
            }
            let genreBonus = sameGenre ? 4.0 : 0.0
            let total = min(100.0, max(0.0, bpmPts + camPts + engPts + vibePts + genreBonus))
            return ScoreBreakdown(
                bpmPoints: bpmPts,
                camelotPoints: camPts,
                energyPoints: engPts,
                vibePoints: max(0.0, vibePts),
                vibeSimilarity: simNorm,
                total: total
            )
        } else {
            // Fallback clássico (50 + 35 + 15) quando ainda não há vetor de vibe
            let bpmPts = bpmScore(bpmA: a.bpm, bpmB: b.bpm)
            let camPts = camelotScore(keyA: a.camelot, keyB: b.camelot)
            let engPts = energyScore(energyA: a.energy, energyB: b.energy)
            let genreBonus = sameGenre ? 5.0 : 0.0
            let total = min(100.0, bpmPts + camPts + engPts + genreBonus)
            return ScoreBreakdown(
                bpmPoints: bpmPts,
                camelotPoints: camPts,
                energyPoints: engPts,
                vibePoints: 0.0,
                vibeSimilarity: nil,
                total: total
            )
        }
    }

    /// Calcula a compatibilidade de 0 a 100 entre duas faixas.
    static func compatibilityScore(from a: TrackMeta, to b: TrackMeta) -> Double {
        scoreBreakdown(from: a, to: b).total
    }

    /// Peso máximo: 50 pontos (com Dual-Deck Tempo Bridge aceita até ±15% de diferença de BPM para beatmatch).
    /// Prefere fortemente mesmo andamento real (1:1) em vez de saltos de metade/dobro do tempo (2:1 / 1:2).
    static func bpmScore(bpmA: Double, bpmB: Double) -> Double {
        guard bpmA > 0, bpmB > 0 else { return 0 }
        let d1 = abs(1.0 - (bpmB / bpmA))
        let d2 = abs(1.0 - ((bpmB * 2.0) / bpmA)) + 0.045
        let d3 = abs(1.0 - ((bpmB * 0.5) / bpmA)) + 0.045
        let minDiff = min(d1, min(d2, d3))
        let maxAllowedDiff = 0.15
        if minDiff > maxAllowedDiff {
            return 0.0
        }
        return 50.0 * pow(1.0 - (minDiff / maxAllowedDiff), 1.35)
    }

    /// Retorna o fator de ajuste alvo (`target_rate_a`) e `initial_rate_b` dividindo grandes diferenças entre os 2 decks.
    static func bestDualRates(bpmA: Double, bpmB: Double) -> (rateA: Float, rateB: Float) {
        guard bpmA > 0, bpmB > 0 else { return (1.0, 1.0) }
        let ratios = [
            bpmB / bpmA,
            (bpmB * 2.0) / bpmA,
            (bpmB * 0.5) / bpmA
        ]
        guard let best = ratios.min(by: { abs(1.0 - $0) < abs(1.0 - $1) }) else { return (1.0, 1.0) }
        let diff = abs(1.0 - best)
        if diff > 0.15 { return (1.0, 1.0) }
        if diff <= 0.08 {
            return (Float(min(max(best, 0.92), 1.08)), 1.0)
        }
        // Divide a ponte de BPM entre Deck A (até ±8%) e Deck B (resto até ±7%)
        let clampedA = min(max(best, 0.92), 1.08)
        let rateB = clampedA / best
        return (Float(clampedA), Float(min(max(rateB, 0.93), 1.07)))
    }

    /// Mantém compatibilidade simples para quem só consulta rateA.
    static func bestTargetRateA(bpmA: Double, bpmB: Double) -> Float {
        bestDualRates(bpmA: bpmA, bpmB: bpmB).rateA
    }

    /// Peso máximo: 35 pontos.
    static func camelotScore(keyA: CamelotKey, keyB: CamelotKey) -> Double {
        let rawDiff = abs(keyA.number - keyB.number)
        let circularDiff = min(rawDiff, 12 - rawDiff)
        let sameLetter = keyA.letter == keyB.letter

        if circularDiff == 0 && sameLetter { return 35.0 } // Mesmo tom (ex.: 8A -> 8A)
        if circularDiff == 1 && sameLetter { return 30.0 } // Vizinho na roda (ex.: 8A -> 9A / 7A)
        if circularDiff == 0 && !sameLetter { return 28.0 } // Relativo maior/menor (ex.: 8A -> 8B)
        if circularDiff == 2 && sameLetter { return 15.0 } // Salto de energia (+2 na roda)
        return 0.0
    }

    /// Peso máximo: 15 pontos.
    static func energyScore(energyA: Double, energyB: Double) -> Double {
        let diff = abs(energyA - energyB)
        return 15.0 * max(0.0, 1.0 - diff)
    }

    private static func normalizedGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? nil : clean
    }

    private static func toTrackMeta(_ meta: TrackMixMetadata, genre: String? = nil) -> TrackMeta? {
        guard let cam = CamelotKey(code: meta.camelot) else { return nil }
        return TrackMeta(
            id: meta.songId,
            bpm: meta.effectiveBPM,
            camelot: cam,
            energy: meta.energy ?? 0.5,
            vibe: meta.vibe,
            genre: normalizedGenre(genre)
        )
    }

    /// Executa algoritmo guloso com consciência de escassez de BPM + Top K controlado + Multi-Start
    /// seguido de reparo global (Relocação Or-Opt-1 + 2-Opt Reversal) para manter a qualidade de mixagem
    /// mesmo em bibliotecas grandes (300–750+ faixas) do início até a última música da fila.
    static func smartShuffle(
        songs: [Song],
        metadata: [String: TrackMixMetadata],
        startingWith anchor: Song? = nil,
        maxAttempts: Int = 6,
        maxDurationSec: TimeInterval = 0.28,
        topK: Int = 3
    ) -> [Song] {
        guard songs.count > 1 else { return songs }

        // Separa em: analisadas no servidor `allin1`, analisadas só localmente e sem análise
        var serverEntries: [(song: Song, meta: TrackMeta)] = []
        var localEntries: [(song: Song, meta: TrackMeta)] = []
        var unanalyzedSongs: [Song] = []
        for s in songs {
            if let raw = metadata[s.id], let tm = toTrackMeta(raw, genre: s.genre) {
                if raw.analyzer == "allin1" {
                    serverEntries.append((s, tm))
                } else {
                    localEntries.append((s, tm))
                }
            } else {
                unanalyzedSongs.append(s)
            }
        }

        // Quando as faixas IA cobrem a maioria (>= locais), unifica todas analisadas em um pool único
        // para evitar quebra artificial no meio da fila entre "allin1" e "local".
        let unifyAnalyzed = serverEntries.count >= localEntries.count
        var finalQueue: [Song] = []
        finalQueue.reserveCapacity(songs.count)

        if unifyAnalyzed {
            let combined = serverEntries + localEntries
            let anchorInCombined = anchor.map { anc in combined.contains(where: { $0.song.id == anc.id }) } ?? false
            if let anchor, !anchorInCombined {
                finalQueue.append(anchor)
            }
            let ordered = bestMixOrder(
                for: combined,
                anchorId: anchorInCombined ? anchor?.id : nil,
                maxAttempts: maxAttempts,
                maxDurationSec: maxDurationSec,
                topK: topK
            )
            finalQueue.append(contentsOf: ordered)

            let remUnanalyzed = (anchor != nil && !anchorInCombined)
                ? unanalyzedSongs.filter { $0.id != anchor?.id }
                : unanalyzedSongs
            finalQueue.append(contentsOf: remUnanalyzed.shuffled())
        } else {
            let anchorInServer = anchor.map { anc in serverEntries.contains(where: { $0.song.id == anc.id }) } ?? false
            let anchorInLocal = anchor.map { anc in localEntries.contains(where: { $0.song.id == anc.id }) } ?? false

            if let anchor, !anchorInServer {
                finalQueue.append(anchor)
            }
            let orderedServer = bestMixOrder(
                for: serverEntries,
                anchorId: anchorInServer ? anchor?.id : nil,
                maxAttempts: maxAttempts,
                maxDurationSec: maxDurationSec,
                topK: topK
            )
            finalQueue.append(contentsOf: orderedServer)

            let remainingLocal = (anchor != nil && !anchorInServer && anchorInLocal)
                ? localEntries.filter { $0.song.id != anchor?.id }
                : localEntries
            let orderedLocal = bestMixOrder(
                for: remainingLocal,
                anchorId: nil,
                maxAttempts: maxAttempts,
                maxDurationSec: maxDurationSec,
                topK: topK
            )
            finalQueue.append(contentsOf: orderedLocal)

            let remUnanalyzed = (anchor != nil && !anchorInServer && !anchorInLocal)
                ? unanalyzedSongs.filter { $0.id != anchor?.id }
                : unanalyzedSongs
            finalQueue.append(contentsOf: remUnanalyzed.shuffled())
        }

        return finalQueue
    }

    /// Monta o relatório detalhado (`SmartShuffleRunLog`) cobrindo TODA a fila (sem corte de 100 faixas).
    static func buildShuffleReport(
        orderedSongs: [Song],
        metadata: [String: TrackMixMetadata]
    ) -> SmartShuffleRunLog {
        var aiCount = 0
        var localCount = 0
        var unCount = 0
        for s in orderedSongs {
            if let m = metadata[s.id] {
                if m.analyzer == "allin1" { aiCount += 1 }
                else { localCount += 1 }
            } else {
                unCount += 1
            }
        }

        var steps: [SmartShuffleStepLog] = []
        steps.reserveCapacity(max(0, orderedSongs.count - 1))
        var sumScore = 0.0
        var minScore = Double.infinity
        var beatmatchPairs = 0
        var scoredPairs = 0

        for i in 1..<orderedSongs.count {
            let prev = orderedSongs[i - 1]
            let cur = orderedSongs[i]
            let mA = metadata[prev.id]
            let mB = metadata[cur.id]
            let tmA = mA.flatMap { toTrackMeta($0, genre: prev.genre) }
            let tmB = mB.flatMap { toTrackMeta($0, genre: cur.genre) }

            let bpmPts: Double
            let camPts: Double
            let engPts: Double
            let vibePts: Double
            let vibeSim: Double?
            let pairTotal: Double
            if let a = tmA, let b = tmB {
                let bd = scoreBreakdown(from: a, to: b)
                bpmPts = bd.bpmPoints
                camPts = bd.camelotPoints
                engPts = bd.energyPoints
                vibePts = bd.vibePoints
                vibeSim = bd.vibeSimilarity
                pairTotal = bd.total
                sumScore += pairTotal
                if pairTotal < minScore { minScore = pairTotal }
                if bpmPts > 0 { beatmatchPairs += 1 }
                scoredPairs += 1
            } else {
                bpmPts = 0
                camPts = 0
                engPts = 0
                vibePts = 0
                vibeSim = nil
                pairTotal = 0
            }

            let tag: String
            if mB?.analyzer == "allin1" { tag = "IA allin1" }
            else if mB != nil { tag = "Local" }
            else { tag = "Sem análise" }

            steps.append(
                SmartShuffleStepLog(
                    position: i + 1,
                    fromTitle: prev.title,
                    toTitle: cur.title,
                    toArtist: cur.artist ?? "",
                    bpmFrom: mA?.effectiveBPM ?? 0,
                    bpmTo: mB?.effectiveBPM ?? 0,
                    camelotFrom: mA?.camelot ?? "—",
                    camelotTo: mB?.camelot ?? "—",
                    energyFrom: mA?.energy ?? 0,
                    energyTo: mB?.energy ?? 0,
                    bpmPoints: bpmPts,
                    camelotPoints: camPts,
                    energyPoints: engPts,
                    vibePoints: vibePts,
                    vibeSimilarity: vibeSim,
                    totalScore: pairTotal,
                    sourceTag: tag
                )
            )
        }

        let avg = scoredPairs > 0 ? (sumScore / Double(scoredPairs)) : 0
        let resolvedMin = (scoredPairs > 0 && minScore.isFinite) ? minScore : 0
        return SmartShuffleRunLog(
            timestamp: Date(),
            totalTracks: orderedSongs.count,
            aiAnalyzedCount: aiCount,
            localAnalyzedCount: localCount,
            unanalyzedCount: unCount,
            beatmatchPairs: beatmatchPairs,
            minScore: resolvedMin,
            averageScore: avg,
            steps: steps
        )
    }

    private static func bestMixOrder(
        for entries: [(song: Song, meta: TrackMeta)],
        anchorId: String?,
        maxAttempts: Int,
        maxDurationSec: TimeInterval,
        topK: Int
    ) -> [Song] {
        guard entries.count >= 2 else { return entries.map(\.song) }

        let n = entries.count
        let metas = entries.map(\.meta)
        let fixedIdx = anchorId.flatMap { aid in entries.firstIndex(where: { $0.song.id == aid }) }

        // Normaliza BPMs para uma oitava [80, 160) e calcula densidade de vizinhos em O(N log N)
        var obpms = [Double](repeating: 120.0, count: n)
        for i in 0..<n {
            var b = max(metas[i].bpm, 20.0)
            while b < 80.0 { b *= 2.0 }
            while b >= 160.0 { b *= 0.5 }
            obpms[i] = b
        }
        let sortedOct = obpms.sorted()

        func lowerBound(_ target: Double) -> Int {
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) >> 1
                if sortedOct[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func upperBound(_ target: Double) -> Int {
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) >> 1
                if sortedOct[mid] <= target { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        var scarcity = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let ob = obpms[i]
            let lo = lowerBound(ob * 0.92)
            let hi = upperBound(ob * 1.08)
            let neighborCnt = max(1, hi - lo)
            scarcity[i] = min(5.0, 80.0 / Double(neighborCnt))
        }

        let startTime = Date()
        let attempts = max(1, maxAttempts)
        var bestSeq: [Int] = []
        var bestRawScore = -Double.infinity

        for _ in 0..<attempts {
            let attempt = generateSingleIndexSequence(
                metas: metas,
                scarcity: scarcity,
                fixedFirst: fixedIdx,
                topK: topK
            )
            if attempt.rawScore > bestRawScore {
                bestRawScore = attempt.rawScore
                bestSeq = attempt.sequence
            }
            if Date().timeIntervalSince(startTime) >= maxDurationSec { break }
        }

        if bestSeq.count >= 3 {
            bestSeq = repairWeakSeams(sequence: bestSeq, metas: metas)
        }
        return bestSeq.map { entries[$0].song }
    }

    /// Monta sequência em O(N²) sem alocações nem sorts por passo, tecendo faixas de BPM raro antes do fim da fila.
    private static func generateSingleIndexSequence(
        metas: [TrackMeta],
        scarcity: [Double],
        fixedFirst: Int?,
        topK: Int
    ) -> (sequence: [Int], rawScore: Double) {
        let n = metas.count
        guard n > 0 else { return ([], 0) }
        var pool = Array(0..<n)
        var result: [Int] = []
        result.reserveCapacity(n)
        var totalRawScore = 0.0

        var current: Int
        if let f = fixedFirst, f < pool.count {
            pool[f] = pool[pool.count - 1]
            pool.removeLast()
            current = f
        } else {
            let r = Int.random(in: 0..<pool.count)
            current = pool[r]
            pool[r] = pool[pool.count - 1]
            pool.removeLast()
        }
        result.append(current)

        let kLimit = max(1, min(topK, 5))
        var topEff = [Double](repeating: -Double.infinity, count: kLimit)
        var topRaw = [Double](repeating: 0.0, count: kLimit)
        var topPos = [Int](repeating: 0, count: kLimit)

        while !pool.isEmpty {
            let curMeta = metas[current]
            let poolCount = pool.count
            let activeK = min(kLimit, poolCount)
            for s in 0..<activeK { topEff[s] = -Double.infinity }

            for pos in 0..<poolCount {
                let candIdx = pool[pos]
                let candMeta = metas[candIdx]
                let bd = scoreBreakdown(from: curMeta, to: candMeta)
                let raw = bd.total
                let vibeOK = (bd.vibeSimilarity ?? 0.6) >= 0.45
                let eff = raw + ((bd.bpmPoints >= 18.0 && vibeOK) ? scarcity[candIdx] : 0.0)

                if eff > topEff[activeK - 1] {
                    var ins = activeK - 1
                    while ins > 0 && eff > topEff[ins - 1] {
                        topEff[ins] = topEff[ins - 1]
                        topRaw[ins] = topRaw[ins - 1]
                        topPos[ins] = topPos[ins - 1]
                        ins -= 1
                    }
                    topEff[ins] = eff
                    topRaw[ins] = raw
                    topPos[ins] = pos
                }
            }

            // Só sorteia entre candidatos realmente próximos do melhor (dentro de 6 pts) para nunca escolher um choque de clima
            var eligibleK = 1
            while eligibleK < activeK && (topEff[0] - topEff[eligibleK]) <= 6.0 {
                eligibleK += 1
            }
            let pickSlot = Int.random(in: 0..<eligibleK)
            let chosenPos = topPos[pickSlot]
            totalRawScore += topRaw[pickSlot]
            current = pool[chosenPos]
            pool[chosenPos] = pool[poolCount - 1]
            pool.removeLast()
            result.append(current)
        }

        return (result, totalRawScore)
    }

    /// Passos rápidos de busca local (Or-Opt-1 Relocação + 2-Opt Reversal) eliminando quebras na cauda da fila.
    private static func repairWeakSeams(sequence: [Int], metas: [TrackMeta]) -> [Int] {
        var seq = sequence
        let n = seq.count
        guard n >= 3 else { return seq }

        func edge(_ a: Int, _ b: Int) -> Double {
            compatibilityScore(from: metas[a], to: metas[b])
        }

        // 1. Relocação Or-Opt-1 nas piores junções (nunca move o índice 0)
        for _ in 0..<160 {
            var worstIdx = 1
            var worstScore = edge(seq[0], seq[1])
            for i in 2..<seq.count {
                let s = edge(seq[i - 1], seq[i])
                if s < worstScore {
                    worstScore = s
                    worstIdx = i
                }
            }
            if worstScore >= 72.0 { break }

            var moved = false
            let candidates = worstIdx > 1 ? [worstIdx, worstIdx - 1] : [worstIdx]
            for candIdx in candidates {
                let node = seq[candIdx]
                let oldPrev = seq[candIdx - 1]
                let hasOldNext = (candIdx + 1) < seq.count
                let removedCost = edge(oldPrev, node)
                    + (hasOldNext ? edge(node, seq[candIdx + 1]) - edge(oldPrev, seq[candIdx + 1]) : 0.0)

                var rest = seq
                rest.remove(at: candIdx)
                let restCount = rest.count
                var bestPos = -1
                var bestNet = 0.5

                for j in 1...restCount {
                    let a = rest[j - 1]
                    let hasB = j < restCount
                    let oldE = hasB ? edge(a, rest[j]) : 0.0
                    let newE = edge(a, node) + (hasB ? edge(node, rest[j]) : 0.0)
                    let net = (newE - oldE) - removedCost
                    if net > bestNet {
                        bestNet = net
                        bestPos = j
                    }
                }

                if bestPos >= 1 {
                    rest.insert(node, at: bestPos)
                    seq = rest
                    moved = true
                    break
                }
            }
            if !moved { break }
        }

        // 2. 2-Opt Reversal para juntar blocos compatíveis que ficaram distantes
        for _ in 0..<60 {
            var didSwap = false
            for i in 1..<(seq.count - 1) {
                let a = seq[i - 1]
                let b = seq[i]
                let curAB = edge(a, b)
                if curAB >= 68.0 { continue }

                var bestGain = 1.0
                var bestJ = -1
                for j in (i + 1)..<seq.count {
                    let c = seq[j]
                    let hasD = (j + 1) < seq.count
                    let curCD = hasD ? edge(c, seq[j + 1]) : 0.0
                    let newAC = edge(a, c)
                    let newBD = hasD ? edge(b, seq[j + 1]) : 0.0
                    let gain = (newAC + newBD) - (curAB + curCD)
                    if gain > bestGain {
                        bestGain = gain
                        bestJ = j
                    }
                }

                if bestJ > i {
                    // Verifica ganho real total considerando pequena assimetria b/a vs a/b na inversão
                    var beforeSlice = curAB + ((bestJ + 1 < seq.count) ? edge(seq[bestJ], seq[bestJ + 1]) : 0.0)
                    for k in i..<bestJ { beforeSlice += edge(seq[k], seq[k + 1]) }

                    var afterSlice = edge(seq[i - 1], seq[bestJ]) + ((bestJ + 1 < seq.count) ? edge(seq[i], seq[bestJ + 1]) : 0.0)
                    for k in stride(from: bestJ, to: i, by: -1) { afterSlice += edge(seq[k], seq[k - 1]) }

                    if afterSlice > beforeSlice + 0.5 {
                        seq[i...bestJ].reverse()
                        didSwap = true
                        break
                    }
                }
            }
            if !didSwap { break }
        }

        return seq
    }

    /// Fallback local offline caso o servidor :4534 não responda a tempo para `/api/transition`.
    static func buildLocalTransitionPlan(
        idA: String,
        metaA: TrackMixMetadata?,
        idB: String,
        metaB: TrackMixMetadata?,
        durationA: Double
    ) -> TransitionPlan {
        let safeDurA = max(durationA, 15.0)
        guard let mA = metaA, let mB = metaB,
              let tmA = toTrackMeta(mA), let tmB = toTrackMeta(mB) else {
            let mixDur = min(8.0, max(3.5, safeDurA * 0.22))
            let fallbackStart = safeDurA > 90.0 ? safeDurA * 0.78 : max(1.0, safeDurA - mixDur - 0.5)
            let mixStart = min(max(safeDurA * 0.50, fallbackStart), max(1.0, safeDurA - mixDur - 0.4))
            return TransitionPlan(
                transitionType: "fade",
                source: "local",
                trackA: TrackATiming(id: idA, bpm: metaA?.effectiveBPM ?? 120.0, rampStartSec: mixStart, mixStartSec: mixStart, mixEndSec: min(safeDurA - 0.1, mixStart + mixDur)),
                trackB: TrackBTiming(id: idB, bpm: metaB?.effectiveBPM ?? 120.0, entrySec: metaB?.cueIn ?? 0.0),
                sync: SyncConfig(targetRateA: 1.0, initialRateB: 1.0, rampDurationSec: 0.0),
                mix: MixConfig(
                    durationSec: mixDur,
                    bars: 4,
                    volumeCurve: AutomixVolumeCurve.overlap.rawValue,
                    eqStyle: AutomixEQStyle.centerBassSwap.rawValue,
                    filterStyle: AutomixFilterStyle.hpInHpOut.rawValue,
                    reverbTail: false,
                    eqSwap: EQSwapConfig(bassSwapAtProgress: 0.5, bassCutDb: -24.0)
                )
            )
        }

        let bpmPts = bpmScore(bpmA: tmA.bpm, bpmB: tmB.bpm)
        let isBeatmatch = bpmPts > 0

        if !isBeatmatch {
            let mixDur = 8.0
            let rawStart = (mA.cueOut >= safeDurA * 0.70 && mA.cueOut <= safeDurA * 0.89)
                ? mA.cueOut
                : (safeDurA > 90.0 ? safeDurA * 0.79 : safeDurA - mixDur - 0.5)
            let mixStart = min(max(safeDurA * 0.66, rawStart), max(safeDurA * 0.66, safeDurA - mixDur - 0.4))
            let safeEntryB = min(max(0.0, mB.cueIn), 36.0)
            return TransitionPlan(
                transitionType: "fade",
                source: "local",
                trackA: TrackATiming(id: idA, bpm: mA.effectiveBPM, rampStartSec: mixStart, mixStartSec: mixStart, mixEndSec: min(safeDurA - 0.1, mixStart + mixDur)),
                trackB: TrackBTiming(id: idB, bpm: mB.effectiveBPM, entrySec: safeEntryB),
                sync: SyncConfig(targetRateA: 1.0, initialRateB: 1.0, rampDurationSec: 0.0),
                mix: MixConfig(
                    durationSec: mixDur,
                    bars: 4,
                    volumeCurve: AutomixVolumeCurve.crossfadeQuickOut.rawValue,
                    eqStyle: AutomixEQStyle.centerBassSwap.rawValue,
                    filterStyle: AutomixFilterStyle.finalNoiseOut.rawValue,
                    reverbTail: true,
                    eqSwap: EQSwapConfig(bassSwapAtProgress: 0.5, bassCutDb: -24.0)
                )
            )
        }

        let dual = bestDualRates(bpmA: mA.effectiveBPM, bpmB: mB.effectiveBPM)
        let targetRate = dual.rateA
        let barSecA = (60.0 / max(mA.effectiveBPM, 60.0)) * 4.0
        let barsCount = (mA.effectiveBPM < 105.0 || safeDurA < 130.0) ? 4 : 8
        let idealMixDur = min(max(barSecA * Double(barsCount) / Double(targetRate), 6.0), 18.0)
        let maxMixStart = max(safeDurA * 0.52, safeDurA - idealMixDur - 0.6)
        let loPct: Double = safeDurA >= 210.0 ? 0.54 : (safeDurA >= 140.0 ? 0.62 : 0.68)
        let fallbackFrac: Double = safeDurA >= 210.0 ? 0.68 : 0.78
        let preferredOut = (mA.cueOut >= safeDurA * loPct && mA.cueOut <= safeDurA * 0.89)
            ? mA.cueOut
            : (safeDurA > 90.0 ? safeDurA * fallbackFrac : safeDurA - idealMixDur - 0.6)
        let mixStart = min(maxMixStart, max(safeDurA * loPct, preferredOut))

        let rateDelta = Double(abs(targetRate - 1.0))
        let totalLeadBars: Double
        if rateDelta < 0.003 {
            totalLeadBars = 0.0
        } else if rateDelta < 0.020 {
            totalLeadBars = 16.0
        } else if rateDelta < 0.045 {
            totalLeadBars = 24.0
        } else {
            totalLeadBars = 32.0
        }

        let rampStart: Double
        let rampDur: Double
        if totalLeadBars <= 0.0 {
            rampStart = mixStart
            rampDur = 0.0
        } else {
            let minRampT = safeDurA * 0.30
            let maxLead = max(0.0, mixStart - minRampT)
            let desiredLead = min(barSecA * totalLeadBars, maxLead >= 6.0 * barSecA ? maxLead : max(2.0, mixStart - 2.0))
            rampStart = max(0.0, mixStart - desiredLead)
            rampDur = desiredLead >= 8.0 * barSecA ? desiredLead * 0.50 : desiredLead
        }

        let safeEntryB = min(max(0.0, mB.cueIn), 36.0)
        let mixEnd = min(safeDurA - 0.15, mixStart + idealMixDur)

        return TransitionPlan(
            transitionType: "beatmatch",
            source: "local",
            trackA: TrackATiming(id: idA, bpm: mA.effectiveBPM, rampStartSec: rampStart, mixStartSec: mixStart, mixEndSec: mixEnd),
            trackB: TrackBTiming(id: idB, bpm: mB.effectiveBPM, entrySec: safeEntryB),
            sync: SyncConfig(targetRateA: targetRate, initialRateB: dual.rateB, rampDurationSec: rampDur),
            mix: MixConfig(
                durationSec: max(2.0, mixEnd - mixStart),
                bars: barsCount,
                volumeCurve: AutomixVolumeCurve.overlap.rawValue,
                eqStyle: AutomixEQStyle.threeBandTransition.rawValue,
                filterStyle: AutomixFilterStyle.hpInHpOut.rawValue,
                reverbTail: false,
                eqSwap: EQSwapConfig(bassSwapAtProgress: 0.5, bassCutDb: -24.0)
            )
        )
    }
}
