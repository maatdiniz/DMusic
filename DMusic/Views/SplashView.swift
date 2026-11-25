import SwiftUI

/// Tela de abertura (Splash View) em continuidade direta com a Launch Screen nativa do iOS.
/// Mantém o logo exatamente na mesma coordenada central da `UILaunchScreen` para eliminar
/// qualquer salto visual enquanto o estado inicial e os álbuns da Home são carregados.
struct SplashView: View {
    @State private var appeared = false

    private let accent = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    accent.opacity(appeared ? 0.18 : 0.0),
                    Color.clear
                ],
                center: .center,
                startRadius: 12,
                endRadius: 170
            )
            .frame(width: 340, height: 340)

            Image("LaunchLogo")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 108, height: 108)

            VStack(spacing: 5) {
                Text("DMusic")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(0.3)

                Text("Hi-Res • Automix")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 94 : 100)

            VStack {
                Spacer()
                SplashWaveDots(accent: accent)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 64)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Abrindo DMusic")
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) {
                appeared = true
            }
        }
    }
}

private struct SplashWaveDots: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin(t * 5.0 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.65 + 0.42 * wave)
                        .opacity(0.35 + 0.65 * wave)
                        .offset(y: -3.0 * wave)
                }
            }
            .frame(height: 18)
        }
    }
}

#Preview {
    SplashView()
}
