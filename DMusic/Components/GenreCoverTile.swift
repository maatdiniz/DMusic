import SwiftUI

extension GenreFamily {
    /// Cor da família nas capas de gênero.
    var tint: Color {
        switch self {
        case .house: return Color(red: 1.00, green: 0.58, blue: 0.12)
        case .techno: return Color(red: 0.93, green: 0.22, blue: 0.27)
        case .trance: return Color(red: 0.62, green: 0.36, blue: 0.98)
        case .drumAndBass: return Color(red: 0.20, green: 0.84, blue: 0.62)
        case .bass: return Color(red: 0.96, green: 0.30, blue: 0.62)
        case .electronic: return Color(red: 0.22, green: 0.80, blue: 0.96)
        case .hipHop: return Color(red: 0.98, green: 0.82, blue: 0.20)
        case .funkBR: return Color(red: 0.42, green: 0.82, blue: 0.24)
        case .rnb: return Color(red: 0.40, green: 0.44, blue: 0.96)
        case .pop: return Color(red: 1.00, green: 0.46, blue: 0.80)
        case .rock: return Color(red: 0.80, green: 0.34, blue: 0.20)
        case .latin: return Color(red: 0.98, green: 0.40, blue: 0.36)
        case .other: return Color(white: 0.62)
        }
    }
}

/// O ícone oficial do app (círculo com barras de onda) desenhado em SwiftUI para poder receber qualquer cor.
/// Proporções tiradas do `AppIcon.png`.
struct DMusicMark: View {
    var color: Color
    var barColor: Color = .black

    private static let heights: [CGFloat] = [131, 282, 490, 202, 366, 167].map { $0 / 876 }
    private static let barWidth: CGFloat = 52.0 / 876
    private static let gap: CGFloat = 38.0 / 876

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                HStack(spacing: Self.gap * d) {
                    ForEach(Self.heights.indices, id: \.self) { i in
                        Capsule()
                            .fill(barColor)
                            .frame(width: Self.barWidth * d, height: Self.heights[i] * d)
                    }
                }
            }
            .frame(width: d, height: d)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Capa de um gênero: ícone do app na cor da família, com ▶ (gapless) e ⚡ (Automix) embutidos.
struct GenreCoverTile: View {
    let family: GenreFamily
    let count: Int
    var width: CGFloat = 132
    var onPlay: () -> Void
    var onAutomix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 0) {
                    DMusicMark(color: family.tint)
                        .frame(width: width * 0.60, height: width * 0.60)
                        .padding(.top, width * 0.09)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    tileButton("play.fill", action: onPlay)
                    tileButton("bolt.fill", action: onAutomix)
                }
                .padding(.bottom, 8)
            }
            .frame(width: width, height: width)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(family.tint.opacity(0.28), lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(family.rawValue).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(count) músicas").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private func tileButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 26)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.borderless)
    }
}

/// Última capa da fileira: leva à biblioteca com todos os gêneros.
struct GenreAllCoverTile: View {
    var width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width * 0.27), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(GenreFamily.allCases.prefix(9))) { fam in
                        DMusicMark(color: fam.tint).frame(width: width * 0.27, height: width * 0.27)
                    }
                }
            }
            .frame(width: width, height: width)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Todos os gêneros").font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Text("Biblioteca de capas").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

#Preview("Capas de gênero") {
    ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
            ForEach([GenreFamily.house, .techno, .trance, .drumAndBass, .hipHop]) { fam in
                GenreCoverTile(family: fam, count: 312, onPlay: {}, onAutomix: {})
            }
            GenreAllCoverTile()
        }
        .padding(16)
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}
