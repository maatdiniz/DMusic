import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayerManager.self) private var player
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @Environment(\.dismiss) private var dismiss
    @State private var djMenu: ActionMenuRequest?
    @State private var showAutomixStudio = false

    private let bgColor = Color(red: 0.055, green: 0.058, blue: 0.068)
    private let cardColor = Color.white.opacity(0.06)

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            List {
                if let current = player.currentSong {
                    Section {
                        nowPlayingCard(current)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        sectionHeader("TOCANDO AGORA")
                    }
                }

                Section {
                    if player.upcoming.isEmpty {
                        emptyUpcomingState
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(player.upcoming, id: \.index) { item in
                            Button { player.jump(to: item.index) } label: {
                                upcomingRow(item.song)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.white.opacity(0.07))
                        }
                        .onDelete { offsets in
                            let items = player.upcoming
                            for i in offsets.sorted(by: >) { player.removeFromQueue(at: items[i].index) }
                        }
                        .onMove { source, destination in
                            let base = (player.upcoming.first?.index ?? 0)
                            player.moveInQueue(from: IndexSet(source.map { $0 + base }), to: destination + base)
                        }
                    }
                } header: {
                    HStack {
                        sectionHeader("A SEGUIR (\(player.upcoming.count))")
                        Spacer()
                        if !player.upcoming.isEmpty {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    player.clearUpcoming()
                                }
                            } label: {
                                Text("Limpar")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.75))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.09), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(bgColor.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .actionMenuSheet($djMenu)
        .sheet(isPresented: $showAutomixStudio) {
            AutomixStudioSheet()
        }
    }

    /// Opções do Modo DJ no painel padrão do app (apresentado localmente: a fila já é um painel).
    private func presentDJMenu() {
        let player = self.player
        var items: [ActionMenuItem] = [
            ActionMenuItem(title: "Nova ordenação inteligente", subtitle: "Reorganiza a fila a partir da música atual", systemImage: "wand.and.stars", style: .accent) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.enableAutomixAndReorganizeFromCurrent()
            },
            ActionMenuItem(title: "Continuar com a mesma fila", systemImage: "arrow.right.circle") {
                if !player.automixEnabled { player.automixEnabled = true }
            },
        ]
        if let current = player.currentSong {
            let genreItems = player.genreFocusItems(for: current) { mode, fams in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.enableAutomixAndReorganizeFromCurrent(focus: mode, families: fams)
            }
            items.insert(contentsOf: genreItems, at: 1)
        }
        if player.automixEnabled {
            items.append(ActionMenuItem(title: "Desativar Modo DJ", systemImage: "power", style: .destructive) {
                player.automixEnabled = false
            })
        }
        djMenu = ActionMenuRequest(
            title: "Modo DJ",
            message: "Deseja manter a fila atual ou gerar uma nova ordenação inteligente a partir da música que está tocando?",
            sections: [items]
        )
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text("Fila de Reprodução")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .bold))
                Text(player.automixEnabled ? "Modo DJ" : "Mix DJ")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(player.automixEnabled ? .white : Color.white.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                player.automixEnabled
                    ? Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.88)
                    : Color.white.opacity(0.09),
                in: Capsule()
            )
            .contentShape(Capsule())
            .onTapGesture {
                presentDJMenu()
            }
            .onLongPressGesture(minimumDuration: 0.42) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showAutomixStudio = true
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(Color.white.opacity(0.48))
    }

    private func nowPlayingCard(_ song: Song) -> some View {
        HStack(spacing: 12) {
            CoverArtView(coverArt: song.coverArt, size: 120, cornerRadius: 8)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }

                Text(ArtistParser.displayString(for: song))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer()

            if let mix = analysisStore.metadata(for: song.id) {
                QualityBadge(text: mix.formattedBPM)
                CamelotBadge(camelot: mix.camelot)
            }

            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.88, blue: 0.42))
        }
        .padding(10)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func upcomingRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            CoverArtView(coverArt: song.coverArt, size: 100, cornerRadius: 8)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }

                Text(ArtistParser.displayString(for: song))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()

            if song.isHiRes { HiResTag() }
            if let mix = analysisStore.metadata(for: song.id) {
                QualityBadge(text: mix.formattedBPM)
                CamelotBadge(camelot: mix.camelot)
            }
            Text(formatTime(Double(song.duration ?? 0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(minWidth: 34, alignment: .trailing)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.28))
        }
        .contentShape(Rectangle())
    }

    private var emptyUpcomingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.35))
            Text("A fila está vazia")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.75))
            Text("Segure uma faixa e escolha “Adicionar à fila”.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.48))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
