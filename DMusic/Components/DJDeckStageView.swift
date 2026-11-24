import SwiftUI

/// Palco da capa na tela de reprodução. Sem pratos: a capa ganha um filete de luz correndo pela borda.
///
/// - `.idle`: capa normal (com deslizar para trocar de faixa).
/// - `.ramping` (ajuste de BPM da faixa A): a capa continua inteira, com a luz correndo pela borda (cor = BPM subindo,
///   descendo ou cravado).
/// - `.mixing` (as duas faixas tocando): o palco vai de borda a borda da tela (sem o recuo lateral); a capa de A desliza
///   para a esquerda e a de B entra pela direita, cada uma mostrando cerca de metade, no tamanho normal e com um vão
///   entre elas; cada uma com sua luz correndo (verde = A, âmbar = B).
/// - `.settling`: B desliza até o centro e A sai pela esquerda; a luz de B se apaga e ela fica como a capa atual.
///
/// As capas ficam sempre retas; só a luz da borda se move.
struct DJDualJogStageView: View {
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
    /// Altura livre entre a base da capa e o título da música (o indicador de BPM fica no meio dela).
    var chipGap: CGFloat = 60
    /// Recuo lateral da tela de reprodução. Na transição de faixa o palco ignora esse recuo e vai de borda a borda.
    var edgeBleed: CGFloat = 20

    // MARK: Cinemática

    private static let cruiseSpeed: Double = 200.0   // °/s ≈ 33⅓ rpm
    private static let morphDuration = 0.65          // capa → centro do prato
    private static let slideDelay = 0.50             // o prato começa a deslizar antes do fim do morph
    private static let slideDuration = 0.85
    private static let settleSlide = 0.80
    private static let dissolveDelay = 0.55
    private static let dissolveDuration = 0.62
    private static var settleTotal: Double { dissolveDelay + dissolveDuration + 0.08 }

    private static let greenLED = Color(red: 0.12, green: 0.88, blue: 0.42)
    private static let amberLED = Color(red: 1.0, green: 0.62, blue: 0.12)

    @State private var phaseStart = Date()
    @State private var spinStartA: Date?
    @State private var spinStartB: Date?
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
                    spinStartA = now.addingTimeInterval(-2)
                case .mixing:
                    // A tela foi recriada no meio do mix: já mostra os pratos formados
                    phaseStart = now.addingTimeInterval(-10)
                    spinStartA = now.addingTimeInterval(-2)
                    spinStartB = now.addingTimeInterval(-2)
                case .settling:
                    phaseStart = now
                    spinStartA = now.addingTimeInterval(-2)
                    spinStartB = now.addingTimeInterval(-2)
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
                    spinStartA = nil
                    spinStartB = nil
                    cameFromRamping = false
                case .ramping:
                    spinStartA = now
                    spinStartB = nil
                    cameFromRamping = false
                    haloOn = liveBPMTrend != 0
                    haloChangedAt = now
                case .mixing:
                    cameFromRamping = (oldMode == .ramping)
                    if oldMode != .ramping || spinStartA == nil { spinStartA = now }
                    spinStartB = now
                case .settling:
                    if spinStartA == nil { spinStartA = now.addingTimeInterval(-2) }
                    if spinStartB == nil { spinStartB = now.addingTimeInterval(-2) }
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
                        phaseStart = phaseStart.addingTimeInterval(delta)
                        spinStartA = spinStartA?.addingTimeInterval(delta)
                        spinStartB = spinStartB?.addingTimeInterval(delta)
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

    /// Ângulo (graus) de um prato que acelera até a velocidade de cruzeiro e segue constante.
    private static func spin(since start: Date?, at date: Date, speed: Double, rampUp: Double) -> Double {
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

    /// Posição vertical (a partir do centro do palco) do indicador de BPM: no vão entre a base da capa e o título,
    /// um pouco mais perto da capa e sempre com folga do título (que tem folga interna própria).
    private func chipOffsetY(S: CGFloat) -> CGFloat {
        let center = chipGap * 0.42
        return S / 2 + min(max(center, 16), max(chipGap - 30, 16))
    }

    // MARK: Fases

    @ViewBuilder
    private func stageContent(side S: CGFloat, at date: Date) -> some View {
        let t = max(0, date.timeIntervalSince(phaseStart))
        let angleA = Self.spin(since: spinStartA, at: date, speed: Self.cruiseSpeed * Double(max(deckARate, 0.5)), rampUp: 0.5)
        let angleB = Self.spin(since: spinStartB, at: date, speed: Self.cruiseSpeed, rampUp: 0.35)

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
        CoverFaceView(coverArt: currentCoverArt, side: S, fill: 0, corner: DJStageMetrics.coverCorner, shadowOpacity: 1)
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
        let accent = Self.rampColor(rate: deckARate)
        let blink = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 7.0))
        let chipAlpha = Double(Self.ease(t / 0.45))
        return ZStack {
            CoverFaceView(coverArt: deckACoverArt ?? currentCoverArt, side: S, fill: 0, corner: DJStageMetrics.coverCorner, shadowOpacity: 1)
            if level > 0.01 {
                CoverHaloRing(side: S, angle: angleA, color: accent)
                    .opacity(level)
            }
            if let bpm = deckABPM, bpm > 0 {
                DJDeckBPMChip(bpm: bpm, trend: liveBPMTrend, accent: accent, blinkOpacity: liveBPMTrend != 0 ? blink : 1.0)
                    .offset(y: chipOffsetY(S: S))
                    .opacity(chipAlpha)
            }
        }
        .frame(width: S, height: S)
    }

    // Capa com a luz correndo pela borda (a mesma do ajuste de BPM)
    private func lightCover(art: String?, side: CGFloat, angle: Double, color: Color, x: CGFloat,
                            haloAlpha: Double = 1, shadow: Double = 1, alpha: Double = 1) -> some View {
        ZStack {
            CoverFaceView(coverArt: art, side: side, fill: 0, corner: DJStageMetrics.coverCorner, shadowOpacity: shadow)
            CoverHaloRing(side: side, angle: angle, color: color)
                .opacity(haloAlpha)
        }
        .offset(x: x)
        .opacity(alpha)
    }

    // As duas faixas tocando: metade de cada capa, no tamanho normal, com um vão entre elas e indo até as bordas da tela.
    // O deslize é por tempo (não acompanha o progresso do mix).
    private func mixingStage(S: CGFloat, t: Double, angleA: Double, angleB: Double) -> some View {
        let W = S + 2 * edgeBleed                                   // largura inteira da tela (sem o recuo lateral)
        let half = (S + DJStageMetrics.coverGap) / 2                // centro de cada capa quando as duas estão em repouso
        let slide = Self.ease((t - Self.slideDelay) / Self.slideDuration)
        let xA = -half * slide                                      // A vai para a esquerda: sobra a parte da direita
        let xB = Self.lerp(W / 2 + S / 2, half, slide)              // B entra pela direita, de fora da tela
        // A luz do ajuste de BPM (se estava acesa) se apaga; só então acende a verde, que é da troca de faixa
        let rampCarry = (cameFromRamping && haloOn) ? 1 - Double(Self.ease(t / 0.35)) : 0
        let haloA = Double(Self.ease((t - Self.slideDelay) / 0.35))   // acende junto com o deslize, não antes
        let chipAlpha = Double(Self.ease((t - 0.45) / 0.4))
        let chipY = chipOffsetY(S: S)

        return ZStack {
            ZStack {
                lightCover(art: deckBCoverArt ?? currentCoverArt, side: S, angle: angleB, color: Self.amberLED, x: xB)
                lightCover(art: deckACoverArt ?? currentCoverArt, side: S, angle: angleA, color: Self.greenLED, x: xA, haloAlpha: haloA)
                if rampCarry > 0.01 {
                    CoverHaloRing(side: S, angle: angleA, color: Self.rampColor(rate: deckARate))
                        .opacity(rampCarry)
                        .offset(x: xA)
                }
            }
            .frame(width: W, height: S)
            .mask { Rectangle().frame(width: W, height: S * 1.5) }

            if chipAlpha > 0.01 {
                // Cada indicador de BPM fica no centro da parte visível da sua capa
                if let bpm = deckABPM, bpm > 0 {
                    DJDeckBPMChip(bpm: bpm, trend: 0, accent: Self.greenLED)
                        .offset(x: (-W / 2 + xA + S / 2) / 2, y: chipY)
                        .opacity(chipAlpha)
                }
                if let bpm = deckBBPM, bpm > 0 {
                    DJDeckBPMChip(bpm: bpm, trend: 0, accent: Self.amberLED)
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
        let half = (S + DJStageMetrics.coverGap) / 2
        let slide = Self.ease(t / Self.settleSlide)
        let xB = Self.lerp(half, 0, slide)
        let xA = Self.lerp(-half, -(W / 2 + S / 2), slide)          // sai de vez pela esquerda
        let dissolve = Self.ease((t - Self.dissolveDelay) / Self.dissolveDuration)
        let chipFade = max(0, 1 - Double(Self.ease(t / 0.3)))

        return ZStack {
            ZStack {
                if slide < 0.99 {
                    lightCover(art: deckACoverArt, side: S, angle: angleA, color: Self.greenLED, x: xA)
                }
                lightCover(art: deckBCoverArt ?? currentCoverArt, side: S, angle: angleB, color: Self.amberLED, x: xB,
                           haloAlpha: Double(1 - dissolve))
            }
            .frame(width: W, height: S)
            .mask { Rectangle().frame(width: W, height: S * 1.5) }

            if chipFade > 0.01, let bpm = deckBBPM, bpm > 0 {
                DJDeckBPMChip(bpm: bpm, trend: 0, accent: Self.amberLED)
                    .offset(x: xB / 2, y: chipOffsetY(S: S))
                    .opacity(chipFade)
            }
        }
        .frame(width: W, height: S)
    }
}

// MARK: - Medidas

enum DJStageMetrics {
    /// Raio dos cantos das capas do palco: quase reto, para aparecer o máximo possível da arte.
    static let coverCorner: CGFloat = 3
    /// Vão entre as duas capas durante a mixagem.
    static let coverGap: CGFloat = 22
}

// MARK: - Capa (sempre reta)

/// Capa que interpola entre "cabe inteira num quadrado" (`fill = 0`) e "preenche a caixa" (`fill = 1`),
/// com raio de canto livre (vira círculo quando `corner == side / 2`).
private struct CoverFaceView: View {
    let coverArt: String?
    let side: CGFloat
    let fill: CGFloat
    let corner: CGFloat
    var shadowOpacity: Double = 0

    @Environment(AuthViewModel.self) private var auth
    @State private var loadedImage: UIImage?

    var body: some View {
        let target = max(side, 1)
        let m = min(max(fill, 0), 1)
        let image = loadedImage ?? coverArt.flatMap { ImageCache.shared.cachedImage(id: $0, size: 600) }
        let (fitW, fitH) = Self.fitted(image, target: target)
        let boxW = fitW + (target - fitW) * m
        let boxH = fitH + (target - fitH) * m

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
        .shadow(color: .black.opacity(0.55 * shadowOpacity), radius: 22 * min(target / 300, 1.2), y: 10)
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

// MARK: - Filete de luz na borda da capa (fase de ajuste de BPM)

/// Dois filetes de luz correndo pela borda da capa, um em cada lado, na velocidade do prato que vai entrar.
private struct CoverHaloRing: View {
    let side: CGFloat
    let angle: Double
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DJStageMetrics.coverCorner + 2, style: .continuous)
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

private struct DJStagePreview: View {
    let mode: DJStageMode
    var body: some View {
        DJDualJogStageView(
            stageMode: mode,
            currentCoverArt: nil, deckACoverArt: nil, deckBCoverArt: nil,
            deckARate: 1.03, deckABPM: 142.4, deckBBPM: 142.4, liveBPMTrend: 1,
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

#Preview("Mixando (meias capas)") { DJStagePreview(mode: .mixing) }
#Preview("Ajuste de BPM") { DJStagePreview(mode: .ramping) }
#Preview("Capa") { DJStagePreview(mode: .idle) }
