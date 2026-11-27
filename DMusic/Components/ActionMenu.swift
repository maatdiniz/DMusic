import SwiftUI

// MARK: - Modelo

/// Uma linha de ação do menu. Com `children` vira um submenu (abre outra página dentro do mesmo painel).
struct ActionMenuItem: Identifiable {
    enum Style { case normal, accent, destructive }

    let id = UUID()
    var title: String
    var subtitle: String? = nil
    var systemImage: String
    var style: Style = .normal
    /// `true` mostra um visto à direita (item selecionado).
    var isSelected: Bool = false
    var children: [ActionMenuItem]? = nil
    var action: (() -> Void)? = nil
}

struct ActionMenuHeader {
    var title: String
    var subtitle: String? = nil
    var coverArt: String? = nil
    var badges: [String] = []
}

/// Pedido de menu: quem chama monta o conteúdo e entrega para `AudioPlayerManager.actionMenu`;
/// um único painel no `MainTabView` apresenta (nada de `.sheet` por linha de lista).
struct ActionMenuRequest: Identifiable {
    let id = UUID()
    var header: ActionMenuHeader? = nil
    var title: String? = nil
    var message: String? = nil
    var sections: [[ActionMenuItem]]

    /// Altura aproximada do conteúdo, para o painel abrir já no tamanho certo.
    var estimatedHeight: CGFloat {
        let rows = sections.reduce(0) { $0 + $1.count }
        let top: CGFloat = header != nil ? 96 : (title != nil ? 62 : 28)
        let msg: CGFloat = message != nil ? 56 : 0
        return top + msg + CGFloat(rows) * 49 + CGFloat(max(sections.count - 1, 0)) * 14 + 44
    }
}

/// Pedido para escolher uma playlist (aberto depois que o menu fecha, para os painéis não se atropelarem).
struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
}

// MARK: - Painel

struct ActionMenuSheet: View {
    let request: ActionMenuRequest
    @Environment(\.dismiss) private var dismiss
    @State private var page: [ActionMenuItem]?
    @State private var pageTitle = ""

    var body: some View {
        ZStack {
            if let page {
                submenu(page)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: page == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DarkSheetTheme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: Página principal

    private var mainPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let header = request.header {
                    ActionMenuHeaderView(header: header)
                        .padding(.top, 22)
                } else if let title = request.title {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 24)
                }
                if let message = request.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                ForEach(Array(request.sections.enumerated()), id: \.offset) { _, items in
                    card(items)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Submenu

    private func submenu(_ items: [ActionMenuItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation { page = nil }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text("Voltar")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1.0))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(pageTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 56, height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 12)

            ScrollView {
                card(items)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Cartão de linhas

    private func card(_ items: [ActionMenuItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ActionMenuDivider() }
                Button {
                    select(item)
                } label: {
                    ActionMenuRow(item: item)
                }
                .buttonStyle(ActionMenuRowStyle())
            }
        }
        .background(DarkSheetTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DarkSheetTheme.cardStroke, lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func select(_ item: ActionMenuItem) {
        UISelectionFeedbackGenerator().selectionChanged()
        if let children = item.children {
            pageTitle = item.title
            withAnimation { page = children }
            return
        }
        item.action?()
        dismiss()
    }
}

// MARK: - Peças visuais

private struct ActionMenuHeaderView: View {
    let header: ActionMenuHeader

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(coverArt: header.coverArt, size: 160, cornerRadius: 10)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(header.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .lineLimit(1)
                }
                if !header.badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(header.badges, id: \.self) { QualityBadge(text: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

private struct ActionMenuRow: View {
    let item: ActionMenuItem

    private var tint: Color {
        switch item.style {
        case .normal: return .white
        case .accent: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .destructive: return Color(red: 1.0, green: 0.36, blue: 0.36)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.style == .normal ? Color.white.opacity(0.78) : tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DarkSheetTheme.footerText)
                }
            }
            Spacer(minLength: 8)
            if item.isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1.0))
            } else if item.children != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ActionMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.09) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ActionMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(DarkSheetTheme.divider)
            .frame(height: 0.5)
            .padding(.leading, 50)
    }
}

// MARK: - Apresentação única

extension View {
    /// Painel de menu e seletor de playlist, apresentados uma única vez na raiz do app.
    func actionMenuHost(_ player: AudioPlayerManager) -> some View {
        modifier(ActionMenuHostModifier(player: player))
    }

    /// Apresenta o painel de menu a partir de um estado local. Necessário dentro de outro painel (ex.: a fila),
    /// porque o SwiftUI não abre dois painéis a partir do mesmo ponto.
    func actionMenuSheet(_ item: Binding<ActionMenuRequest?>) -> some View {
        sheet(item: item) { request in
            ActionMenuSheet(request: request)
                .presentationDetents(ActionMenuDetents.detents(for: request))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
                .presentationBackground(DarkSheetTheme.background)
        }
    }
}

private enum ActionMenuDetents {
    static func detents(for request: ActionMenuRequest) -> Set<PresentationDetent> {
        let height = request.estimatedHeight
        return height > 620 ? [.large] : [.height(height)]
    }
}

private struct ActionMenuHostModifier: ViewModifier {
    @Bindable var player: AudioPlayerManager

    func body(content: Content) -> some View {
        content
            .actionMenuSheet($player.actionMenu)
            .sheet(item: $player.playlistPicker) { request in
                AddToPlaylistSheet(songs: request.songs)
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $player.genrePicker) { request in
                GenrePickerSheet(request: request)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}

#Preview("Menu de faixa") {
    ActionMenuSheet(request: ActionMenuRequest(
        header: ActionMenuHeader(title: "Control Freak", subtitle: "Boys Noize", badges: ["FLAC 24-bit", "140 BPM", "8A"]),
        sections: [
            [
                ActionMenuItem(title: "Mix DJ nesta playlist", subtitle: "Automix a partir desta faixa", systemImage: "waveform.path.ecg", style: .accent),
                ActionMenuItem(title: "Mix DJ com toda a biblioteca", subtitle: "Busca todas as músicas do servidor", systemImage: "dot.radiowaves.left.and.right", style: .accent),
            ],
            [
                ActionMenuItem(title: "Tocar a seguir", systemImage: "text.insert"),
                ActionMenuItem(title: "Adicionar à fila", systemImage: "text.append"),
                ActionMenuItem(title: "Favoritar", systemImage: "heart"),
                ActionMenuItem(title: "Adicionar à playlist", systemImage: "music.note.list"),
            ],
            [
                ActionMenuItem(title: "Ir para o artista", systemImage: "music.mic"),
                ActionMenuItem(title: "Remover download", systemImage: "trash", style: .destructive),
            ],
        ]
    ))
    .environment(AuthViewModel())
}
