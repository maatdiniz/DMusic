import SwiftUI

/// Quadrado de reticências exibido no centro da tela enquanto o app faz algo pesado (montar a fila do Mix DJ,
/// buscar a biblioteca completa…). Só aparece se a tarefa passar de 250 ms, para não piscar em operações rápidas,
/// e nunca bloqueia toques: a interface continua responsiva por baixo.
struct BusyIndicatorOverlay: View {
    let message: String?
    @State private var visibleMessage: String?

    var body: some View {
        ZStack {
            if let visibleMessage {
                BusyIndicatorCard(message: visibleMessage)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.12), value: visibleMessage)
        .allowsHitTesting(false)
        .task(id: message) {
            guard let message else {
                visibleMessage = nil
                return
            }
            if visibleMessage == nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            visibleMessage = message
        }
    }
}

private struct BusyIndicatorCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            EllipsisDots()
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 148, height: 118)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// Três pontos em onda (• • •), no azul de destaque do app.
private struct EllipsisDots: View {
    private let accent = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin(t * 5.2 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(accent)
                        .frame(width: 10, height: 10)
                        .scaleEffect(0.62 + 0.46 * wave)
                        .opacity(0.38 + 0.62 * wave)
                        .offset(y: -3.5 * wave)
                }
            }
            .frame(height: 22)
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        BusyIndicatorCard(message: "Montando a fila do Mix DJ")
    }
}
