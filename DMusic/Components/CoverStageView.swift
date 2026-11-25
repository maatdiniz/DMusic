import SwiftUI

/// Palco da capa na tela de reprodução. A capa ganha um filete de luz (halo) correndo pela borda nas transições.
///
/// - `.idle`: capa normal (com deslizar para trocar de faixa).
/// - `.ramping` (ajuste de BPM da faixa A): a capa continua inteira, com a luz correndo pela borda (cor = BPM subindo
///   ou descendo).
/// - `.mixing` (as duas faixas tocando): o palco vai de borda a borda da tela (sem o recuo lateral); a capa de A desliza
///   para a esquerda e a de B entra pela direita, cada uma mostrando cerca de metade, no tamanho normal e com um vão
///   entre elas; cada uma com sua luz correndo (verde = A, âmbar = B).
/// - `.settling`: B desliza até o centro e A sai pela esquerda; a luz de B se apaga e ela fica como a capa atual.
///
/// As capas ficam sempre retas; só a luz da borda se move.
struct CoverStageView: View {
    let stageMode: CoverStageMode
    let currentCoverArt: String?
    let coverArtA: String?
    let coverArtB: String?
    let rateA: Float
    let bpmA: Double?
    let bpmB: Double?
    let liveBPMTrend: Int
    let isPlaying: Bool
    let onSettlingFinished: () -> Void
    let onSwipeNext: () -> Void
    let onSwipePrevious: () -> Void
    /// Altura livre entre a base da capa e o título da música (o indicador de BPM fica no meio dela).
    var chipGap: CGFloat = 60
    /// Recuo lateral da tela de reprodução. Na transição de faixa o palco ignora esse recuo e vai de borda a borda.
    var edgeBleed: CGFloat = 20

    // MARK: Cinemática

    private static let haloSpeed: Double = 200.0     // °/s do filete de luz na borda
    private static let slideDelay = 0.50             // início do deslize lateral das meias capas
    private static let slideDuration = 0.85
    private static let settleSlide = 0.80
    private static let dissolveDelay = 0.55
    private static let dissolveDuration = 0.62
    private static var settleTotal: Double { dissolveDelay + dissolveDuration + 0.08 }

    private static let greenLED = Color(red: 0.12, green: 0.88, blue: 0.42)
    private static let amberLED = Color(red: 1.0, green: 0.62, blue: 0.12)

    @State private var phaseStart = Date()
    @State private var haloStartA: Date?
    @State private var haloStartB: Date?
    @State private var pausedAt: Date?
    @State private var cameFromRamping = false
    /// Luz do ajuste de BPM: acesa só enquanto o BPM está mudando (sobe/desce), apagada depois.
    @State private var haloOn = false
    @State private var haloChangedAt = Date.distantPast
    @State private var settleTask: Task<Void, Never>?
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
                            .frame(width: side + 2 * edgeBleed, height: geo.size.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            }
            .onAppear {
                let now = Date()
                pausedAt = isPlaying ? nil : now
                haloOn = (stageMode == .ramping && liveBPMTrend != 0)
                switch stageMode {
                case .idle:
                    phaseStart = now
                case .ramping:
                    phaseStart = now.addingTimeInterval(-10)
                    haloStartA = now.addingTimeInterval(-2)
                case .mixing:
                    // A tela foi recriada no meio do mix: já mostra as meias capas posicionadas
                    phaseStart = now.addingTimeInterval(-10)
                    haloStartA = now.addingTimeInterval(-2)
                    haloStartB = now.addingTimeInterval(-2)
                case .settling:
                    phaseStart = now
                    haloStartA = now.addingTimeInterval(-2)
                    haloStartB = now.addingTimeInterval(-2)
                    if isPlaying { scheduleSettleFinish(after: Self.settleTotal) }
                }
            }
            .onChange(of: stageMode) { oldMode, newMode in
                let now = Date()
                settleTask?.cancel()
                settleTask = nil
                pausedAt = isPlaying ? nil : now
                phaseStart = now
                switch newMode {
                case .idle:
                    haloStartA = nil
                    haloStartB = nil
                    cameFromRamping = false
                case .ramping:
                    haloStartA = now
                    haloStartB = nil
                    cameFromRamping = false
                    haloOn = liveBPMTrend != 0
                    haloChangedAt = now
                case .mixing:
                    cameFromRamping = (oldMode == .ramping)
                    if oldMode != .ramping || haloStartA == nil { haloStartA = now }
                    haloStartB = now
                case .settling:
                    if haloStartA == nil { haloStartA = now.addingTimeInterval(-2) }
                    if haloStartB == nil { haloStartB = now.addingTimeInterval(-2) }
                    if isPlaying { scheduleSettleFinish(after: Self.settleTotal) }
                }
            }
            .onChange(of: liveBPMTrend) { _, trend in
                // A luz acompanha a troca de BPM: acende quando começa a mudar e apaga quando termina
                guard stageMode == .ramping else { return }
                let active = trend != 0
                if active != haloOn {
                    haloOn = active
                    haloChangedAt = Date()
                }
            }
            .onChange(of: isPlaying) { wasPlaying, nowPlaying in
                let now = Date()
                if wasPlaying && !nowPlaying {
                    pausedAt = now
                    settleTask?.cancel()
                    settleTask = nil
                } else if !wasPlaying && nowPlaying {
                    if let paused = pausedAt {
                        // Desconta o tempo parado para a animação continuar de onde parou
                        let delta = now.timeIntervalSince(paused)
                        phaseStart = clickedPhaseStart(after: delta)
                        haloStartA = haloStartA?.addingTimeInterval(delta)
                        haloStartB = haloStartB?.addingTimeInterval(delta)
                        pausedAt = nil
                    }
                    if stageMode == .settling {
                        let elapsed = max(0, now.timeIntervalSince(phaseStart))
                        scheduleSettleFinish(after: max(0.05, Self.settleTotal - elapsed))
                    }
                }
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
    }

    private func clickedPhaseStart(after delta: TimeInterval) -> Date {
        phaseStart.addingTimeInterval(delta)
    }

    private func scheduleSettleFinish(after delay: Double) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            onSettlingFinished()
        }
    }

    // MARK: Funções puras

    private static func ease(_ x: Double) -> CGFloat {
        let t = min(max(x, 0), 1)
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// Ângulo acumulado (graus) do filete de luz que acelera suavemente e percorre a borda da capa.
    private static func haloAngle(since start: Date?, at date: Date, speed: Double, rampUp: Double) -> Double {
        guard let start else { return 0 }
        let dt = max(0, date.timeIntervalSince(start))
        guard dt > 0 else { return 0 }
        let r = max(rampUp, 0.01)
        return dt <= r ? 0.5 * (speed / r) * dt * dt : 0.5 * speed * r + speed * (dt - r)
    }

    /// Cor da luz do ajuste de BPM: roxo = subindo, coral = descendo. Nunca verde (o verde é só da troca de faixa).
    private static func rampColor(rate: Float) -> Color {
        rate >= 1 ? Color(red: 0.72, green: 0.36, blue: 1.0) : Color(red: 1.0, green: 0.34, blue: 0.38)
    }

    /// Posição vertical (a partir do centro do palco) do indicador de BPM: no vão entre a base da capa e o título.
    private func chipOffsetY(S: CGFloat) -> CGFloat {
        let center = chipGap * 0.42
        return S / 2 + min(max(center, 16), max(chipGap - 30, 16))
    }

    // MARK: Fases

    @ViewBuilder
    private func stageContent(side S: CGFloat, at date: Date) -> some View {
        let t = max(0, date.timeIntervalSince(phaseStart))
        let angleA = Self.haloAngle(since: haloStartA, at: date, speed: Self.haloSpeed * Double(max(rateA, 0.5)), rampUp: 0.5)
        let angleB = Self.haloAngle(since: haloStartB, at: date, speed: Self.haloSpeed, rampUp: 0.35)

        switch stageMode {
        case .idle:
            idleStage(S: S)
        case .ramping:
            rampingStage(S: S, t: t, date: date, angleA: angleA)
        case .mixing:
            mixingStage(S: S, t: t, angleA: angleA, angleB: angleB)
        case .settling:
            settlingStage(S: S, t: t, angleA: angleA, angleB: angleB)
        }
    }

    // Capa normal, com deslizar para trocar de faixa
    private func idleStage(S: CGFloat) -> some View {
        CoverFaceView(coverArt: currentCoverArt, side: S)
            .frame(width: S, height: S)
            .offset(x: coverDragX)
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
                            withAnimation(.easeOut(duration: 0.18)) { coverDragX = -S * 0.6 }
                            onSwipeNext()
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        } else if dx > 65 {
                            withAnimation(.easeOut(duration: 0.18)) { coverDragX = S * 0.6 }
                            onSwipePrevious()
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        } else {
                            withAnimation(.spring(duration: 0.32)) { coverDragX = 0 }
                        }
                    }
            )
    }

    // Ajuste de BPM: capa intacta; a luz corre pela borda só enquanto o BPM está mudando
    private func rampingStage(S: CGFloat, t: Double, date: Date, angleA: Double) -> some View {
        let sinceChange = date.timeIntervalSince(haloChangedAt)
        let level = haloOn ? Double(Self.ease(sinceChange / 0.4)) : 1 - Double(Self.ease(sinceChange / 0.5))
        let accent = Self.rampColor(rate: rateA)
        let blink = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 7.0))
        let chipAlpha = Double(Self.ease(t / 0.45))
        return ZStack {
            CoverFaceView(coverArt: coverArtA ?? currentCoverArt, side: S)
            if level > 0.01 {
                CoverHaloRing(side: S, angle: angleA, color: accent)
                    .opacity(level)
            }
            if let bpm = bpmA, bpm > 0 {
                CoverBPMChip(bpm: bpm, trend: liveBPMTrend, accent: accent, blinkOpacity: liveBPMTrend != 0 ? blink : 1.0)
                    .offset(y: chipOffsetY(S: S))
                    .opacity(chipAlpha)
            }
        }
        .frame(width: S, height: S)
    }

    // Capa com a luz correndo pela borda
    private func lightCover(art: String?, side: CGFloat, angle: Double, color: Color, x: CGFloat, haloAlpha: Double = 1) -> some View {
        ZStack {
            CoverFaceView(coverArt: art, side: side)
            CoverHaloRing(side: side, angle: angle, color: color)
                .opacity(haloAlpha)
        }
        .offset(x: x)
    }

    // As duas faixas tocando: metade de cada capa, no tamanho normal, com um vão entre elas e indo até as bordas da tela.
    private func mixingStage(S: CGFloat, t: Double, angleA: Double, angleB: Double) -> some View {
        let W = S + 2 * edgeBleed                                       // largura inteira da tela (sem o recuo lateral)
        let half = (S + CoverStageMetrics.coverGap) / 2                 // centro de cada capa quando as duas estão em repouso
        let slide = Self.ease((t - Self.slideDelay) / Self.slideDuration)
        let xA = -half * slide                                          // A vai para a esquerda: sobra a parte da direita
        let xB = Self.lerp(W / 2 + S / 2, half, slide)                  // B entra pela direita, de fora da tela
        // A luz do ajuste de BPM (se estava acesa) se apaga; só então acende a verde, que é da troca de faixa
        let rampCarry = (cameFromRamping && haloOn) ? 1 - Double(Self.ease(t / 0.35)) : 0
        let haloA = Double(Self.ease((t - Self.slideDelay) / 0.35))     // acende junto com o deslize, não antes
        let chipAlpha = Double(Self.ease((t - 0.45) / 0.4))
        let chipY = chipOffsetY(S: S)

        return ZStack {
            ZStack {
                lightCover(art: coverArtB ?? currentCoverArt, side: S, angle: angleB, color: Self.amberLED, x: xB)
                lightCover(art: coverArtA ?? currentCoverArt, side: S, angle: angleA, color: Self.greenLED, x: xA, haloAlpha: haloA)
                if rampCarry > 0.01 {
                    CoverHaloRing(side: S, angle: angleA, color: Self.rampColor(rate: rateA))
                        .opacity(rampCarry)
                        .offset(x: xA)
                }
            }
            .frame(width: W, height: S)
            .mask { Rectangle().frame(width: W, height: S * 1.5) }

            if chipAlpha > 0.01 {
                // Cada indicador de BPM fica no centro da parte visível da sua capa
                if let bpm = bpmA, bpm > 0 {
                    CoverBPMChip(bpm: bpm, trend: 0, accent: Self.greenLED)
                        .offset(x: (-W / 2 + xA + S / 2) / 2, y: chipY)
                        .opacity(chipAlpha)
                }
                if let bpm = bpmB, bpm > 0 {
                    CoverBPMChip(bpm: bpm, trend: 0, accent: Self.amberLED)
                        .offset(x: (xB - S / 2 + W / 2) / 2, y: chipY)
                        .opacity(chipAlpha)
                }
            }
        }
        .frame(width: W, height: S)
    }

    // Fim do mix: B vai ao centro, A sai pela esquerda e a luz de B se apaga; as capas nunca mudam de tamanho
    private func settlingStage(S: CGFloat, t: Double, angleA: Double, angleB: Double) -> some View {
        let W = S + 2 * edgeBleed
        let half = (S + CoverStageMetrics.coverGap) / 2
        let slide = Self.ease(t / Self.settleSlide)
        let xB = Self.lerp(half, 0, slide)
        let xA = Self.lerp(-half, -(W / 2 + S / 2), slide)          // sai de vez pela esquerda
        let dissolve = Self.ease((t - Self.dissolveDelay) / Self.dissolveDuration)
        let chipFade = max(0, 1 - Double(Self.ease(t / 0.3)))

        return ZStack {
            ZStack {
                if slide < 0.99 {
                    lightCover(art: coverArtA, side: S, angle: angleA, color: Self.greenLED, x: xA)
                }
                lightCover(art: coverArtB ?? currentCoverArt, side: S, angle: angleB, color: Self.amberLED, x: xB,
                           haloAlpha: Double(1 - dissolve))
            }
            .frame(width: W, height: S)
            .mask { Rectangle().frame(width: W, height: S * 1.5) }

            if chipFade > 0.01, let bpm = bpmB, bpm > 0 {
                CoverBPMChip(bpm: bpm, trend: 0, accent: Self.amberLED)
                    .offset(x: xB / 2, y: chipOffsetY(S: S))
                    .opacity(chipFade)
            }
        }
        .frame(width: W, height: S)
    }
}

// MARK: - Medidas

enum CoverStageMetrics {
    /// Raio dos cantos das capas do palco: quase reto, para aparecer o máximo possível da arte.
    static let coverCorner: CGFloat = 3
    /// Vão entre as duas capas durante a mixagem.
    static let coverGap: CGFloat = 22
}

// MARK: - Pílula de BPM sob a capa

/// Pílula compacta com BPM animado em tempo real exibida sob as capas durante a rampa e a transição.
struct CoverBPMChip: View {
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

// MARK: - Capa (sempre reta)

private struct CoverFaceView: View {
    let coverArt: String?
    let side: CGFloat

    @Environment(AuthViewModel.self) private var auth
    @State private var loadedImage: UIImage?

    var body: some View {
        let target = max(side, 1)
        let image = loadedImage ?? coverArt.flatMap { ImageCache.shared.cachedImage(id: $0, size: 600) }
        let (boxW, boxH) = Self.fitted(image, target: target)
        let corner = CoverStageMetrics.coverCorner

        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: max(14, target * 0.12), weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    )
            }
        }
        .frame(width: boxW, height: boxH)
        .clipShape(RoundedRectangle(cornerRadius: min(corner, min(boxW, boxH) / 2), style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 22 * min(target / 300, 1.2), y: 10)
        .frame(width: target, height: target)
        .task(id: coverArt) {
            guard let coverArt else { loadedImage = nil; return }
            if let hit = ImageCache.shared.cachedImage(id: coverArt, size: 600) {
                loadedImage = hit
            } else {
                loadedImage = nil
                loadedImage = await ImageCache.shared.image(id: coverArt, size: 600, client: auth.client)
            }
        }
    }

    private static func fitted(_ image: UIImage?, target: CGFloat) -> (CGFloat, CGFloat) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return (target, target) }
        let aspect = image.size.width / image.size.height
        return aspect >= 1 ? (target, target / aspect) : (target * aspect, target)
    }
}

// MARK: - Filete de luz na borda da capa

/// Dois filetes de luz correndo pela borda da capa, um em cada lado.
private struct CoverHaloRing: View {
    let side: CGFloat
    let angle: Double
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CoverStageMetrics.coverCorner + 2, style: .continuous)
        let p = (angle / 360).truncatingRemainder(dividingBy: 1)
        let length = 0.14
        ZStack {
            shape.stroke(color.opacity(0.20), lineWidth: 1.6)
            ForEach([0.0, 0.5], id: \.self) { offset in
                segment(shape, start: (p + offset).truncatingRemainder(dividingBy: 1), length: length)
            }
        }
        .frame(width: side + 4, height: side + 4)
    }

    @ViewBuilder
    private func segment(_ shape: RoundedRectangle, start: Double, length: Double) -> some View {
        let end = start + length
        ZStack {
            shape.trim(from: start, to: min(end, 1))
                .stroke(color, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            if end > 1 {
                shape.trim(from: 0, to: end - 1)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
        }
        .shadow(color: color.opacity(0.7), radius: 6)
    }
}

// MARK: - Previews

private struct CoverStagePreview: View {
    let mode: CoverStageMode
    var body: some View {
        CoverStageView(
            stageMode: mode,
            currentCoverArt: nil, coverArtA: nil, coverArtB: nil,
            rateA: 1.03, bpmA: 142.4, bpmB: 142.4, liveBPMTrend: 1,
            isPlaying: true,
            onSettlingFinished: {}, onSwipeNext: {}, onSwipePrevious: {}
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.055, blue: 0.07))
        .environment(AuthViewModel())
        .preferredColorScheme(.dark)
    }
}

#Preview("Mixando (meias capas)") { CoverStagePreview(mode: .mixing) }
#Preview("Ajuste de BPM") { CoverStagePreview(mode: .ramping) }
#Preview("Capa") { CoverStagePreview(mode: .idle) }
