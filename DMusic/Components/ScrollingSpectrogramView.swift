import SwiftUI

// MARK: - Modelo de canais (animação das trocas de faixa)

/// Mantém um canal por faixa (`songId`) e anima a posição/altura/opacidade de cada um a cada quadro.
/// Assim a troca de deck (o B vira o A) vira um deslizamento contínuo, e não uma troca brusca de dados:
/// - 1 → 2 decks: o canal da faixa B sobe de baixo enquanto o A encolhe para a metade de cima;
/// - promoção (fim do mix): o canal de B sobe e cresce até ocupar tudo, e o de A sai por cima e some;
/// - pulo de faixa: o canal antigo some e o novo aparece (cruzamento suave);
/// - a onda de uma faixa recém-extraída entra em fade, sem "estourar" na tela.
@MainActor
final class SpectrogramLaneModel {
    enum Role { case top, bottom, exiting }

    struct Lane: Identifiable {
        var id: String
        var role: Role
        var y: Double, h: Double, alpha: Double, waveAlpha: Double
        var targetY: Double, targetH: Double, targetAlpha: Double
        var time: Double
        var rate: Double
    }

    private(set) var lanes: [Lane] = []
    private(set) var overviewId: String?
    private(set) var overviewPrevId: String?
    private(set) var overviewBlend: Double = 1
    private var lastDate: Date?

    func update(now: Date, snap: AutomixAudioEngine.LiveDeckSnapshot, dual: Bool, hasData: (String) -> Bool) {
        let isFirstFrame = (lastDate == nil)
        let dt = lastDate.map { min(max(now.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastDate = now
        let move = isFirstFrame ? 1.0 : 1 - exp(-dt * 11)
        let fade = isFirstFrame ? 1.0 : 1 - exp(-dt * 8)
        let wave = isFirstFrame ? 1.0 : 1 - exp(-dt * 4.5)

        let topId = snap.songIdA
        let bottomId = dual ? snap.songIdB : nil
        let timeB = snap.hasStartedIncoming ? snap.timeB : (snap.plan?.trackB.entrySec ?? snap.timeB)
        let topH = bottomId != nil ? 0.5 : 1.0
        var promoted = false

        func timing(_ id: String) -> (time: Double, rate: Double) {
            if id == snap.songIdA { return (snap.timeA, Double(max(snap.rateA, 0.5))) }
            if id == snap.songIdB { return (timeB, Double(max(snap.rateB, 0.5))) }
            return (0, 1)
        }

        for (id, role) in [(topId, Role.top), (bottomId, Role.bottom)] {
            guard let id else { continue }
            let t = timing(id)
            let ty = role == .top ? 0.0 : 0.5
            let th = role == .top ? topH : 0.5
            if let i = lanes.firstIndex(where: { $0.id == id }) {
                if role == .top && lanes[i].role == .bottom { promoted = true }
                lanes[i].role = role
                lanes[i].targetY = ty
                lanes[i].targetH = th
                lanes[i].targetAlpha = 1
                lanes[i].time = t.time
                lanes[i].rate = t.rate
            } else {
                var lane = Lane(
                    id: id, role: role,
                    y: ty, h: th, alpha: isFirstFrame ? 1 : 0, waveAlpha: isFirstFrame && hasData(id) ? 1 : 0,
                    targetY: ty, targetH: th, targetAlpha: 1,
                    time: t.time, rate: t.rate
                )
                if !isFirstFrame && role == .bottom { lane.y = 1.0; lane.h = 0.5 } // sobe de baixo
                lanes.append(lane)
            }
        }

        for i in lanes.indices where lanes[i].id != topId && lanes[i].id != bottomId {
            if lanes[i].role != .exiting {
                if promoted && lanes[i].role == .top { lanes[i].targetY = -lanes[i].h } // sai deslizando por cima
                lanes[i].role = .exiting
                lanes[i].targetAlpha = 0
            }
            lanes[i].time += dt * lanes[i].rate // continua rolando enquanto some
        }

        for i in lanes.indices {
            lanes[i].y += (lanes[i].targetY - lanes[i].y) * move
            lanes[i].h += (lanes[i].targetH - lanes[i].h) * move
            lanes[i].alpha += (lanes[i].targetAlpha - lanes[i].alpha) * fade
            let waveTarget = hasData(lanes[i].id) ? 1.0 : 0.0
            lanes[i].waveAlpha += (waveTarget - lanes[i].waveAlpha) * wave
        }
        lanes.removeAll { $0.role == .exiting && $0.alpha < 0.02 }

        // Barra de visão geral: cruza entre a faixa anterior e a atual
        let overviewTarget = snap.hasStartedIncoming ? snap.songIdB : snap.songIdA
        if overviewTarget != overviewId {
            overviewPrevId = overviewId
            overviewId = overviewTarget
            overviewBlend = isFirstFrame ? 1 : 0
        }
        overviewBlend = min(1, overviewBlend + dt / 0.45)
    }
}

/// Visualizador Espectrograma / Waveform RGB rolante a 60 FPS inspirado no Pioneer Rekordbox.
/// - Ocupa a largura inteira da tela (sem moldura nem cantos arredondados).
/// - Bandas RGB (Vermelho = Graves/Bumbo, Verde/Amarelo = Médios/Vocais, Azul/Ciano = Agudos).
/// - A grade de batidas e compassos é a do servidor (a mesma que o motor usa para mixar).
/// - Cada faixa tem seu canal; as trocas de faixa e de deck são animadas (ver `SpectrogramLaneModel`).
struct ScrollingSpectrogramView: View {
    @Environment(AudioPlayerManager.self) private var player
    @Environment(TrackAnalysisStore.self) private var analysisStore

    /// Cache indexado por `songId` para nunca apagar a onda do Deck A quando `currentSong` muda para a Faixa B no início do mix.
    @State private var spectralCache: [String: TrackSpectralData] = [:]
    @State private var model = SpectrogramLaneModel()
    @State private var windowSeconds: Double = 8.0 // Zoom: 6s, 8s, 14s

    private let zoomSteps: [Double] = [6.0, 8.0, 14.0]
    private let deckAColor = Color(red: 0.16, green: 0.86, blue: 0.48)
    private let deckBColor = Color(red: 1.0, green: 0.68, blue: 0.16)
    private static let deckAColor = Color(red: 0.16, green: 0.86, blue: 0.48)
    private static let deckBColor = Color(red: 1.0, green: 0.68, blue: 0.16)
    private static let playheadColor = Color(red: 1.0, green: 0.24, blue: 0.28)
    private static let stageColor = Color(red: 0.04, green: 0.045, blue: 0.06)
    private static let playheadFraction: CGFloat = 0.35

    var body: some View {
        let snap = player.liveDeckSnapshot()
        let activeIdA = snap.songIdA ?? player.currentSong?.id
        let activeIdB = snap.songIdB ?? player.activeTransitionPlan?.trackB.id ?? player.nextSongInQueue?.id
        // Chaves reativas: re-disparam a extração assim que `prepareIncomingAutomix` termina de baixar/armar a faixa B em cache!
        let extractKeyA = "\(activeIdA ?? "")|\(player.currentSong?.id ?? "")"
        let extractKeyB = "\(activeIdB ?? "")|\(player.activeTransitionPlan?.trackB.id ?? "")|\(player.preparedMixHint ?? "")"

        // 30 fps basta para a onda rolar com um deck só (≈1,5 px por quadro); 60 fps só durante a mixagem
        TimelineView(.animation(minimumInterval: player.djStageMode != .idle ? 1.0 / 60.0 : 1.0 / 30.0, paused: !player.isPlaying)) { timeline in
            let liveSnap = player.liveDeckSnapshot()
            let liveDual = (liveSnap.songIdB != nil && (liveSnap.plan != nil || liveSnap.hasStartedIncoming || liveSnap.phase == .ramping || liveSnap.phase == .mixing))
            let cache = spectralCache
            let _ = model.update(now: timeline.date, snap: liveSnap, dual: liveDual, hasData: { cache[$0] != nil })
            let lanes = model.lanes
            let window = windowSeconds
            let plan = liveSnap.plan

            VStack(spacing: 0) {
                rekordboxHeader(snap: liveSnap, showDual: liveDual)

                Divider().background(Color.white.opacity(0.12))

                // Canais de onda (toda a largura da tela)
                Canvas { ctx, size in
                    Self.drawLanes(ctx: &ctx, size: size, lanes: lanes, cache: cache, plan: plan, window: window)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.stageColor)

                Divider().background(Color.white.opacity(0.12))

                // Barra de visão geral da faixa ativa (cruza suavemente quando a faixa muda)
                let ovId = model.overviewId
                let ovPrev = model.overviewPrevId
                let ovBlend = model.overviewBlend
                let ovTime = liveSnap.hasStartedIncoming ? liveSnap.timeB : liveSnap.timeA
                let ovDuration = max(liveSnap.hasStartedIncoming ? liveSnap.durationB : liveSnap.durationA, 1.0)
                let ovPlan = liveSnap.hasStartedIncoming ? nil : plan
                Canvas { ctx, size in
                    Self.drawOverview(
                        ctx: &ctx, size: size,
                        current: ovId.flatMap { cache[$0] },
                        previous: ovBlend < 1 ? ovPrev.flatMap { cache[$0] } : nil,
                        blend: ovBlend, currentTime: ovTime, duration: ovDuration, plan: ovPlan
                    )
                }
                .frame(height: 30)
                .background(Color(red: 0.055, green: 0.06, blue: 0.08))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: extractKeyA) {
            await ensureExtracted(songId: activeIdA)
        }
        .task(id: extractKeyB) {
            await ensureExtracted(songId: activeIdB)
        }
    }

    // MARK: - Cabeçalho Estilo Rekordbox (Decks A e B • BPM ao vivo + Pitch % + Zoom)

    @ViewBuilder
    private func rekordboxHeader(snap: AutomixAudioEngine.LiveDeckSnapshot, showDual: Bool) -> some View {
        let baseBPMA = snap.nominalBPMA > 0
            ? snap.nominalBPMA
            : (snap.songIdA.flatMap { analysisStore.metadata(for: $0)?.effectiveBPM } ?? 0)
        let liveBPMA = baseBPMA > 0 ? baseBPMA * Double(snap.rateA) : 0
        let pitchPctA = (Double(snap.rateA) - 1.0) * 100.0

        let baseBPMB = snap.nominalBPMB > 0
            ? snap.nominalBPMB
            : (snap.songIdB.flatMap { analysisStore.metadata(for: $0)?.effectiveBPM } ?? 0)
        let liveBPMB = baseBPMB > 0 ? baseBPMB * Double(snap.rateB) : 0
        let pitchPctB = (Double(snap.rateB) - 1.0) * 100.0

        VStack(spacing: 5) {
            HStack(spacing: 8) {
                // Deck A
                HStack(spacing: 5) {
                    Text("A")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(deckAColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if liveBPMA > 0 {
                        Text(String(format: "%.2f", liveBPMA))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(abs(pitchPctA) >= 0.3 ? (pitchPctA > 0 ? Color(red: 0.78, green: 0.48, blue: 1.0) : Color(red: 1.0, green: 0.42, blue: 0.45)) : .white)
                            .monospacedDigit()
                        Text("BPM")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    if abs(pitchPctA) >= 0.1 {
                        Text(String(format: "%+.1f%%", pitchPctA))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(pitchPctA > 0 ? Color(red: 0.78, green: 0.48, blue: 1.0) : Color(red: 1.0, green: 0.42, blue: 0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                }

                Spacer(minLength: 4)

                // Estado da fase (SYNC / MIX)
                if snap.phase == .ramping {
                    Text(pitchPctA > 0.2 ? "SYNC ↑" : (pitchPctA < -0.2 ? "SYNC ↓" : "SYNC"))
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.0, green: 0.68, blue: 0.16), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if snap.phase == .mixing {
                    HStack(spacing: 4) {
                        Text("MIX")
                            .font(.system(size: 9.5, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(deckAColor, in: Capsule())

                        let absErr = abs(snap.phaseErrorMs)
                        let lockText = absErr < 3.0 ? "SYNC 0ms" : String(format: "AUTO %+.0fms", snap.phaseErrorMs)
                        let lockCol: Color = absErr < 3.0 ? deckAColor : Color(red: 1.0, green: 0.68, blue: 0.16)
                        Text(lockText)
                            .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                            .foregroundStyle(lockCol)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(lockCol.opacity(0.16), in: Capsule())
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Zoom cíclico (6s / 8s / 14s)
                Button {
                    if let idx = zoomSteps.firstIndex(of: windowSeconds) {
                        windowSeconds = zoomSteps[(idx + 1) % zoomSteps.count]
                    } else {
                        windowSeconds = 8.0
                    }
                } label: {
                    Text("\(Int(windowSeconds))s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if showDual, let idB = snap.songIdB {
                let titleB = player.queue.first(where: { $0.id == idB })?.title ?? "Próxima faixa"
                HStack(spacing: 5) {
                    Text("B")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(deckBColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if liveBPMB > 0 {
                        Text(String(format: "%.2f", liveBPMB))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(deckBColor)
                            .monospacedDigit()
                    }

                    if abs(pitchPctB) >= 0.1 {
                        Text(String(format: "%+.1f%%", pitchPctB))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(deckBColor)
                    }

                    if !snap.hasStartedIncoming {
                        Text("CUE")
                            .font(.system(size: 8.5, weight: .black, design: .rounded))
                            .foregroundStyle(deckBColor)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(deckBColor.opacity(0.18), in: Capsule())
                    }

                    Text(titleB)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.075, green: 0.082, blue: 0.105))
        .animation(.easeInOut(duration: 0.30), value: showDual)
        .animation(.easeInOut(duration: 0.22), value: snap.phase)
    }

    // MARK: - Desenho dos canais (estático e sem estado: não depende de isolamento de ator)

    private static func drawLanes(
        ctx: inout GraphicsContext,
        size: CGSize,
        lanes: [SpectrogramLaneModel.Lane],
        cache: [String: TrackSpectralData],
        plan: TransitionPlan?,
        window: Double
    ) {
        // Canais que estão saindo ficam por baixo dos que estão entrando
        for lane in lanes.sorted(by: { ($0.role == .exiting ? 0 : 1) < ($1.role == .exiting ? 0 : 1) }) {
            let rect = CGRect(x: 0, y: size.height * lane.y, width: size.width, height: max(0, size.height * lane.h))
            guard rect.height > 1, lane.alpha > 0.01 else { continue }
            drawLane(ctx: &ctx, rect: rect, lane: lane, data: cache[lane.id], plan: plan, window: window)
            if lane.role == .bottom {
                ctx.fill(Path(CGRect(x: 0, y: rect.minY, width: size.width, height: 1)), with: .color(.white.opacity(0.18 * lane.alpha)))
            }
        }

        // Agulha fixa (estilo Rekordbox, em 35% da largura)
        let playheadX = size.width * playheadFraction
        var ph = Path()
        ph.move(to: CGPoint(x: playheadX, y: 0))
        ph.addLine(to: CGPoint(x: playheadX, y: size.height))
        ctx.stroke(ph, with: .color(playheadColor), lineWidth: 2.0)
        var tri = Path()
        tri.move(to: CGPoint(x: playheadX - 5, y: 0))
        tri.addLine(to: CGPoint(x: playheadX + 5, y: 0))
        tri.addLine(to: CGPoint(x: playheadX, y: 6))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(playheadColor))
    }

    /// Primeiro índice de `array` (ordenado) com valor >= `x`.
    private static func lowerBound(_ array: [Double], _ x: Double) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func drawLane(
        ctx: inout GraphicsContext,
        rect: CGRect,
        lane: SpectrogramLaneModel.Lane,
        data: TrackSpectralData?,
        plan: TransitionPlan?,
        window: Double
    ) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.opacity = lane.alpha

            let currentTime = lane.time
            let rate = lane.rate
            let playheadX = rect.minX + rect.width * playheadFraction
            let pxPerWallSec = Double(rect.width) / window
            let midY = rect.midY
            let maxAmp = rect.height * 0.44

            var centerLine = Path()
            centerLine.move(to: CGPoint(x: rect.minX, y: midY))
            centerLine.addLine(to: CGPoint(x: rect.maxX, y: midY))
            layer.stroke(centerLine, with: .color(.white.opacity(0.08)), lineWidth: 0.75)

            guard let data, !data.columns.isEmpty else {
                // Onda ainda sendo extraída: aviso discreto em vez de canal vazio
                let text = layer.resolve(Text("Analisando forma de onda…").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.32)))
                layer.draw(text, at: CGPoint(x: rect.midX, y: midY), anchor: .center)
                return
            }

            func xForTrackTime(_ t: Double) -> CGFloat {
                playheadX + CGFloat((t - currentTime) / rate * pxPerWallSec)
            }

            let visWallLeft = Double(playheadX - rect.minX) / pxPerWallSec
            let visWallRight = Double(rect.maxX - playheadX) / pxPerWallSec
            let tMin = max(0.0, currentTime - visWallLeft * rate - 0.1)
            let tMax = min(data.duration, currentTime + visWallRight * rate + 0.1)

            // 1. Zona de mixagem e de rampa de BPM planejadas
            if let plan {
                if plan.trackA.id == lane.id {
                    let xMix0 = xForTrackTime(plan.trackA.mixStartSec)
                    let xMix1 = xForTrackTime(plan.trackA.mixEndSec)
                    if xMix1 > rect.minX && xMix0 < rect.maxX {
                        let r = CGRect(x: max(rect.minX, xMix0), y: rect.minY, width: min(rect.maxX, xMix1) - max(rect.minX, xMix0), height: rect.height)
                        layer.fill(Path(r), with: .color(deckAColor.opacity(0.10)))
                    }
                    if plan.trackA.rampStartSec < plan.trackA.mixStartSec - 0.2 && abs(plan.sync.targetRateA - 1.0) >= 0.003 {
                        let xR0 = xForTrackTime(plan.trackA.rampStartSec)
                        let xR1 = xForTrackTime(min(plan.trackA.mixStartSec, plan.trackA.rampStartSec + plan.sync.rampDurationSec))
                        if xR1 > rect.minX && xR0 < rect.maxX {
                            let color: Color = plan.sync.targetRateA > 1.0 ? Color(red: 0.72, green: 0.36, blue: 1.0) : Color(red: 1.0, green: 0.34, blue: 0.38)
                            let r = CGRect(x: max(rect.minX, xR0), y: rect.minY, width: min(rect.maxX, xR1) - max(rect.minX, xR0), height: rect.height)
                            layer.fill(Path(r), with: .color(color.opacity(0.10)))
                        }
                    }
                } else if plan.trackB.id == lane.id {
                    let xIn0 = xForTrackTime(plan.trackB.entrySec)
                    let xIn1 = xForTrackTime(plan.trackB.entrySec + plan.mix.durationSec)
                    if xIn1 > rect.minX && xIn0 < rect.maxX {
                        let r = CGRect(x: max(rect.minX, xIn0), y: rect.minY, width: min(rect.maxX, xIn1) - max(rect.minX, xIn0), height: rect.height)
                        layer.fill(Path(r), with: .color(deckBColor.opacity(0.10)))
                    }
                }
            }

            // 2. Colunas RGB espectrais (a onda entra em fade quando a extração termina)
            layer.drawLayer { waveLayer in
                waveLayer.opacity = lane.waveAlpha
                let startIdx = max(0, Int(floor(tMin * data.columnsPerSecond)))
                let endIdx = min(data.columns.count - 1, Int(ceil(tMax * data.columnsPerSecond)))
                let colW = max(1.6, CGFloat((1.0 / data.columnsPerSecond) / rate * pxPerWallSec) + 0.4)
                guard startIdx <= endIdx else { return }
                for idx in startIdx...endIdx {
                    let col = data.columns[idx]
                    let x = xForTrackTime(Double(idx) / data.columnsPerSecond)
                    if x + colW < rect.minX || x > rect.maxX { continue }
                    let l = Double(col.low) / 255.0
                    let m = Double(col.mid) / 255.0
                    let h = Double(col.high) / 255.0
                    let amp = max(l, max(m * 0.92, h * 0.85))
                    let barH = max(1.5, CGFloat(amp) * maxAmp * 2.0)
                    let color = Color(red: min(1.0, l * 1.15 + m * 0.45), green: min(1.0, m * 0.95 + h * 0.55 + l * 0.18), blue: min(1.0, h * 1.20 + m * 0.15))
                    waveLayer.fill(Path(CGRect(x: x, y: midY - barH * 0.5, width: colW, height: barH)), with: .color(color.opacity(0.92)))
                }
            }

            // 3. Grade de batidas e compassos: SEMPRE a do servidor (não a do plano nem a detectada no aparelho)
            let beatColor = Color.white.opacity(0.32)
            let downbeatColor = Color(red: 1.0, green: 0.30, blue: 0.25)
            var i = lowerBound(data.beats, tMin)
            while i < data.beats.count, data.beats[i] <= tMax {
                let x = xForTrackTime(data.beats[i])
                var line = Path()
                line.move(to: CGPoint(x: x, y: rect.minY))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
                layer.stroke(line, with: .color(beatColor), lineWidth: 0.9)
                i += 1
            }
            var j = lowerBound(data.downbeats, tMin)
            while j < data.downbeats.count, data.downbeats[j] <= tMax {
                let x = xForTrackTime(data.downbeats[j])
                var line = Path()
                line.move(to: CGPoint(x: x, y: rect.minY))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
                layer.stroke(line, with: .color(downbeatColor.opacity(0.92)), lineWidth: 1.8)
                layer.fill(Path(CGRect(x: x - 3, y: rect.minY, width: 6, height: 4)), with: .color(downbeatColor))
                j += 1
            }

            // 4. Marcadores de ponto de mixagem (saída de A / entrada de B)
            if let plan {
                let cue: (time: Double, color: Color)? =
                    plan.trackA.id == lane.id ? (plan.trackA.mixStartSec, deckAColor)
                    : (plan.trackB.id == lane.id ? (plan.trackB.entrySec, deckBColor) : nil)
                if let cue {
                    let x = xForTrackTime(cue.time)
                    if x >= rect.minX - 4 && x <= rect.maxX + 4 {
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: rect.minY))
                        line.addLine(to: CGPoint(x: x, y: rect.maxY))
                        layer.stroke(line, with: .color(cue.color), lineWidth: 2.0)
                    }
                }
            }
        }
    }

    // MARK: - Barra de visão geral (base)

    private static func drawOverview(
        ctx: inout GraphicsContext,
        size: CGSize,
        current: TrackSpectralData?,
        previous: TrackSpectralData?,
        blend: Double,
        currentTime: Double,
        duration: Double,
        plan: TransitionPlan?
    ) {
        let safeDur = max(duration, 1.0)
        if let plan, plan.trackA.mixStartSec > 2 {
            let x0 = CGFloat(min(max(plan.trackA.mixStartSec / safeDur, 0), 1)) * size.width
            let x1 = CGFloat(min(max(plan.trackA.mixEndSec / safeDur, 0), 1)) * size.width
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)), with: .color(deckAColor.opacity(0.22)))
        }
        func bars(_ data: TrackSpectralData, opacity: Double) {
            guard !data.columns.isEmpty, opacity > 0.01 else { return }
            let bins = max(60, Int(size.width / 2.0))
            let colsPerBin = max(1, data.columns.count / bins)
            let binW = size.width / CGFloat(bins)
            for b in 0..<bins {
                let s = b * colsPerBin
                let e = min(data.columns.count, s + colsPerBin)
                if s >= e { break }
                var maxL: UInt8 = 0, maxM: UInt8 = 0, maxH: UInt8 = 0
                for k in s..<e {
                    let c = data.columns[k]
                    if c.low > maxL { maxL = c.low }
                    if c.mid > maxM { maxM = c.mid }
                    if c.high > maxH { maxH = c.high }
                }
                let l = Double(maxL) / 255.0, m = Double(maxM) / 255.0, h = Double(maxH) / 255.0
                let barH = max(2, CGFloat(max(l, max(m, h))) * (size.height - 4))
                let color = Color(red: min(1, l * 1.1 + m * 0.4), green: min(1, m * 0.9 + h * 0.5), blue: min(1, h * 1.15))
                ctx.fill(
                    Path(CGRect(x: CGFloat(b) * binW, y: size.height - barH - 2, width: max(1.2, binW - 0.5), height: barH)),
                    with: .color(color.opacity(0.85 * opacity))
                )
            }
        }
        if let previous { bars(previous, opacity: 1 - blend) }
        if let current { bars(current, opacity: blend) }

        let curX = CGFloat(min(max(currentTime / safeDur, 0), 1)) * size.width
        var p = Path()
        p.move(to: CGPoint(x: curX, y: 0))
        p.addLine(to: CGPoint(x: curX, y: size.height))
        ctx.stroke(p, with: .color(.white), lineWidth: 1.8)
    }

    // MARK: - Extração & Cache por songId

    private func ensureExtracted(songId: String?) async {
        guard let songId, spectralCache[songId] == nil else { return }
        guard let url = player.localFileURL(for: songId) else { return }
        let bpmHint = analysisStore.metadata(for: songId)?.effectiveBPM ?? 124.0
        guard var extracted = await SpectralWaveformExtractor.shared.loadOrExtract(
            songId: songId,
            fileURL: url,
            bpmHint: bpmHint
        ) else { return }

        // A grade vem do servidor (a mesma que decide e executa a mixagem). A detectada no aparelho só serve de reserva offline.
        if let grid = await TrackGridCache.shared.grid(for: songId, client: player.mixClient) {
            extracted = TrackSpectralData(
                songId: extracted.songId,
                duration: extracted.duration,
                columnsPerSecond: extracted.columnsPerSecond,
                columns: extracted.columns,
                beats: grid.beats,
                downbeats: grid.downbeats
            )
        }

        // Limita o cache local a 8 faixas, sem nunca descartar as que estão tocando ou prestes a tocar
        if spectralCache.count >= 8 {
            let snap = player.liveDeckSnapshot()
            let keep = Set([snap.songIdA, snap.songIdB, player.currentSong?.id, player.nextSongInQueue?.id].compactMap { $0 })
            if let victim = spectralCache.keys.first(where: { !keep.contains($0) }) {
                spectralCache.removeValue(forKey: victim)
            }
        }
        spectralCache[songId] = extracted
    }
}
