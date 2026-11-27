import SwiftUI
import Combine

enum DarkSheetTheme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.068)
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.07)
    static let headerText = Color.white.opacity(0.48)
    static let footerText = Color.white.opacity(0.46)
    static let secondaryText = Color.white.opacity(0.58)
}

struct DarkSheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
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
}

struct DarkCardSection<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(DarkSheetTheme.headerText)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(DarkSheetTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DarkSheetTheme.cardStroke, lineWidth: 0.7)
            )
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(DarkSheetTheme.footerText)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct DarkCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(DarkSheetTheme.divider)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

struct DarkLabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(DarkSheetTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct DarkToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.subheadline)
            .foregroundStyle(.white)
            .tint(Color(red: 0.12, green: 0.88, blue: 0.42))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

struct DarkMenuPickerRow<SelectionValue: Hashable>: View {
    let title: String
    @Binding var selection: SelectionValue
    let valueLabel: String
    let options: [(value: SelectionValue, label: String)]

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach(options, id: \.value) { opt in
                    Button {
                        selection = opt.value
                    } label: {
                        if opt.value == selection {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(valueLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.38))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct DarkNavRow<Destination: View>: View {
    let title: String
    var icon: String? = nil
    var value: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .frame(width: 20)
                }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Spacer()
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @Environment(CacheSettings.self) private var settings
    @Environment(RecentSongsCache.self) private var recents
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayerManager.self) private var player
    @Environment(AuthViewModel.self) private var auth
    @Environment(ScrobbleManager.self) private var scrobbler
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @Environment(TransitionAuditStore.self) private var transitionAudit
    @Environment(\.dismiss) private var dismiss
    @State private var coverUsage: Int64 = 0
    @State private var showMixWarning = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var player = player
        NavigationStack {
            VStack(spacing: 0) {
                DarkSheetHeader(title: "Ajustes") { dismiss() }

                ScrollView {
                    VStack(spacing: 18) {
                        DarkCardSection(
                            "Reprodução",
                            footer: "O Automix sincroniza grade constante de batidas, BPM, Roda de Camelot (1A–12B) e Vibe acústico 24D (\(analysisStore.items.count) faixas sincronizadas), alinhando frases musicais de 4 compassos com equalização DJ e saída suave. Álbuns ouvidos em ordem mantêm Gapless puro."
                        ) {
                            DarkMenuPickerRow(
                                title: "Wi‑Fi",
                                selection: $settings.wifiBitrate,
                                valueLabel: CacheSettings.bitrateLabel(settings.wifiBitrate),
                                options: CacheSettings.bitrateOptions.map { ($0, CacheSettings.bitrateLabel($0)) }
                            )
                            DarkCardDivider()
                            DarkMenuPickerRow(
                                title: "Dados móveis",
                                selection: $settings.cellularBitrate,
                                valueLabel: CacheSettings.bitrateLabel(settings.cellularBitrate),
                                options: CacheSettings.bitrateOptions.map { ($0, CacheSettings.bitrateLabel($0)) }
                            )
                            DarkCardDivider()
                            DarkToggleRow(title: "Automix (BPM + Tom Camelot)", isOn: $player.automixEnabled)
                            DarkCardDivider()
                            DarkToggleRow(title: "Retomar de onde parou", isOn: $settings.resumePlayback)
                            DarkCardDivider()
                            DarkToggleRow(title: "Tocar junto com outros apps", isOn: Binding(
                                get: { player.mixWithOtherApps },
                                set: { on in
                                    // Ligar exige confirmação: o iOS pode tirar os controles da tela de bloqueio
                                    if on { showMixWarning = true } else { player.mixWithOtherApps = false }
                                }
                            ))
                        }

                        DarkCardSection(
                            "Auditoria de Transições",
                            footer: "Inspecione cada mixagem executada, julgue os parâmetros aplicados e salve sua receita personalizada para que o par (A → B) toque exatamente como você prefere na próxima vez."
                        ) {
                            DarkNavRow(
                                title: "Auditar Transições e Receitas",
                                icon: "waveform.badge.magnifyingglass",
                                value: transitionAudit.history.isEmpty ? nil : "\(transitionAudit.history.count)"
                            ) {
                                TransitionAuditView()
                            }
                            DarkCardDivider()
                            DarkLabeledRow(
                                title: "Transições registradas",
                                value: "\(transitionAudit.history.count)"
                            )
                            DarkCardDivider()
                            DarkLabeledRow(
                                title: "Receitas personalizadas",
                                value: "\(transitionAudit.overrides.count)"
                            )
                        }

                        DarkCardSection(
                            "Compensação de Volume",
                            footer: settings.volumeCompensation.note
                        ) {
                            DarkMenuPickerRow(
                                title: "Nivelamento",
                                selection: $settings.volumeCompensation,
                                valueLabel: settings.volumeCompensation.title,
                                options: VolumeCompensationLevel.allCases.map { ($0, $0.title) }
                            )
                        }
                        .onChange(of: settings.volumeCompensation) { _, newValue in
                            player.applyVolumeCompensation(newValue)
                        }

                        DarkCardSection(
                            "Cache de capas",
                            footer: "Sem limite de tamanho. Capas de músicas baixadas são sempre mantidas."
                        ) {
                            DarkLabeledRow(title: "Em uso", value: formatBytes(coverUsage))
                            DarkCardDivider()
                            actionRow("Limpar cache de capas", destructive: true) {
                                Task { await ImageCache.shared.clear(); await refresh() }
                            }
                        }

                        DarkCardSection(
                            "Músicas tocadas recentemente",
                            footer: "Guarda no aparelho o arquivo das faixas ouvidas, para tocar sem rede. As menos recentes saem primeiro. Downloads manuais não são afetados."
                        ) {
                            DarkMenuPickerRow(
                                title: "Limite",
                                selection: $settings.recentLimitMB,
                                valueLabel: CacheSettings.label(settings.recentLimitMB),
                                options: CacheSettings.recentOptionsMB.map { ($0, CacheSettings.label($0)) }
                            )
                            DarkCardDivider()
                            DarkToggleRow(title: "Salvar só no Wi‑Fi", isOn: $settings.cacheOnlyWifi)
                            DarkCardDivider()
                            DarkLabeledRow(title: "Em uso", value: formatBytes(recents.usedBytes))
                            DarkCardDivider()
                            DarkLabeledRow(title: "Músicas", value: "\(recents.entries.count)")
                            DarkCardDivider()
                            actionRow("Limpar músicas recentes", destructive: true) {
                                recents.clear(protecting: playingIds)
                            }
                        }

                        DarkCardSection("Integração") {
                            DarkNavRow(
                                title: "Last.fm e Scrobbles",
                                value: scrobbler.pending.isEmpty ? nil : "\(scrobbler.pending.count) na fila"
                            ) {
                                LastFMView()
                            }
                        }

                        DarkCardSection(
                            "Servidor de Mixagem (allin1)",
                            footer: "Calcula estrutura musical (intro, verso, refrão, outro), BPM, downbeats e tonalidade Camelot no servidor e entrega o roteiro de transição ao app."
                        ) {
                            if let health = analysisStore.serverHealth {
                                DarkLabeledRow(
                                    title: "Status",
                                    value: health.scanning ? "Analisando (\(health.analyzed)/\(health.totalNavidrome))" : "Online (\(health.analyzed)/\(health.totalNavidrome))"
                                )
                                DarkCardDivider()
                                DarkLabeledRow(title: "Analisador", value: health.analyzer)
                            } else {
                                DarkLabeledRow(title: "Status", value: "Offline / Não conectado")
                            }
                            if let mc = player.mixClient {
                                DarkCardDivider()
                                DarkLabeledRow(title: "Endereço", value: mc.baseURL)
                                DarkCardDivider()
                                Button {
                                    Task { await analysisStore.syncFromServer(mixClient: mc) }
                                } label: {
                                    HStack {
                                        Text("Sincronizar tags (BPM / Camelot)")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        if analysisStore.isSyncingServer {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(analysisStore.isSyncingServer)
                                DarkCardDivider()
                                actionRow("Reescanear biblioteca no servidor") {
                                    Task {
                                        try? await mc.triggerScan()
                                        await analysisStore.refreshHealth(mixClient: mc)
                                    }
                                }
                            }
                            DarkCardDivider()
                            DarkNavRow(
                                title: "Log Completo e Ordem do Aleatório",
                                icon: "doc.text.magnifyingglass"
                            ) {
                                AutomixLogsView()
                            }
                            DarkCardDivider()
                            DarkNavRow(
                                title: "Guia de Cores e Mixagens",
                                icon: "book.pages"
                            ) {
                                AutomixGuideView()
                            }
                        }

                        DarkCardSection("Downloads") {
                            DarkLabeledRow(title: "Faixas baixadas", value: "\(downloads.songs.count)")
                        }

                        DarkCardSection("Conta") {
                            DarkLabeledRow(title: "Servidor", value: auth.serverURL)
                            DarkCardDivider()
                            DarkLabeledRow(title: "Usuário", value: auth.username)
                            DarkCardDivider()
                            actionRow("Sair", destructive: true) {
                                dismiss()
                                auth.logout()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
            .background(DarkSheetTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await refresh() }
            .onChange(of: settings.recentLimitMB) { _, _ in recents.trim(protecting: playingIds) }
        }
        .preferredColorScheme(.dark)
        .alert("Tocar junto com outros apps", isPresented: $showMixWarning) {
            Button("Cancelar", role: .cancel) {}
            Button("Ativar") { player.mixWithOtherApps = true }
        } message: {
            Text("Com esta opção o DMusic continua tocando enquanto você usa outros apps, sem pausar. Em troca, o iOS pode deixar de mostrar os controles do DMusic (play, pausa e próxima) na tela de bloqueio e na Central de Controle. Se isso acontecer, desligue a opção para tê-los de volta.")
        }
    }

    private func actionRow(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? Color(red: 1.0, green: 0.36, blue: 0.38) : .white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playingIds: Set<String> { player.currentSong.map { [$0.id] } ?? [] }
    private func refresh() async { coverUsage = await ImageCache.shared.usage() }
}

/// Tela de Logs do Automix & Explicação da Ordem do Aleatório Inteligente (`SmartShuffler`)
struct AutomixLogsView: View {
    @Environment(AudioPlayerManager.self) private var player
    @Environment(TrackAnalysisStore.self) private var analysisStore
    @State private var selectedTab = 1

    var body: some View {
        VStack(spacing: 0) {
            Picker("Visualização", selection: $selectedTab) {
                Text("Log Completo").tag(1)
                Text("Ordem do Aleatório").tag(0)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if selectedTab == 0 {
                smartShuffleReportView
            } else {
                LiveConsoleLogView()
            }
        }
        .navigationTitle("Log Completo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectedTab == 1 {
                    Button(role: .destructive) {
                        AppLogger.shared.clearLog()
                    } label: {
                        Label("Limpar", systemImage: "trash")
                    }
                } else {
                    Button("Limpar", role: .destructive) {
                        player.clearLogs()
                    }
                    .disabled(player.lastSmartShuffleLog == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var smartShuffleReportView: some View {
        let report: SmartShuffleRunLog? = player.lastSmartShuffleLog ?? (
            player.queue.count > 1
                ? SmartShuffler.buildShuffleReport(orderedSongs: player.queue, metadata: analysisStore.items)
                : nil
        )

        if let report {
            List {
                Section {
                    LabeledContent("Faixas na fila", value: "\(report.totalTracks)")
                    LabeledContent("Analisadas com IA (allin1)", value: "\(report.aiAnalyzedCount)")
                    LabeledContent("Analisadas localmente", value: "\(report.localAnalyzedCount)")
                    LabeledContent("Sem análise", value: "\(report.unanalyzedCount)")
                    LabeledContent("Transições com Beatmatch", value: "\(report.beatmatchPairs) / \(max(report.steps.count, 0))")
                    LabeledContent("Pior encaixe na fila", value: "\(Int(report.minScore.rounded())) / 100 pts")
                    LabeledContent("Compatibilidade média", value: "\(Int(report.averageScore.rounded())) / 100 pts")
                } header: {
                    Text("Resumo da Fila Atual")
                } footer: {
                    Text("Pontuação de cada encaixe (0–100 pts): BPM (até 36 pts, ±15%) + Vibe/Timbre 24D (até 36 pts) + Tom Camelot (até 20 pts) + Energia (até 8 pts) + Bônus de Gênero (+4 pts).")
                }

                Section {
                    ForEach(report.steps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("#\(step.position)")
                                    .font(.caption.monospacedDigit().weight(.black))
                                    .foregroundStyle(.secondary)
                                Text(step.toTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if step.sourceTag != "IA allin1" {
                                    Text(step.sourceTag)
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(step.sourceTag == "Local" ? .orange : .secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                }
                                Spacer()
                                scorePill(score: step.totalScore)
                            }

                            if !step.toArtist.isEmpty {
                                Text("Após \"\(step.fromTitle)\" • \(step.toArtist)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("Após \"\(step.fromTitle)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 8) {
                                Label(
                                    "\(Int(step.bpmFrom.rounded()))→\(Int(step.bpmTo.rounded())) (+\(Int(step.bpmPoints.rounded())))",
                                    systemImage: "metronome"
                                )
                                Label(
                                    "\(step.camelotFrom)→\(step.camelotTo) (+\(Int(step.camelotPoints.rounded())))",
                                    systemImage: "music.quarternote.3"
                                )
                                if let vibeSim = step.vibeSimilarity {
                                    Label(
                                        "V:\(Int((vibeSim * 100).rounded()))% (+\(Int(step.vibePoints.rounded())))",
                                        systemImage: "sparkles"
                                    )
                                } else {
                                    Label(
                                        "E:\(Int((step.energyTo * 100).rounded()))% (+\(Int(step.energyPoints.rounded())))",
                                        systemImage: "bolt.fill"
                                    )
                                }
                            }
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Como a Ordem Foi Escolhida (Passo a Passo)")
                }
            }
        } else {
            ContentUnavailableView(
                "Nenhuma Fila Aleatória Ativa",
                systemImage: "shuffle",
                description: Text("Inicie uma playlist ou lista de músicas no modo Aleatório com o Automix ligado para ver a pontuação detalhada de BPM, Tom Camelot e Energia de cada faixa.")
            )
        }
    }

    private func scorePill(score: Double) -> some View {
        let pts = Int(score.rounded())
        let color: Color = pts >= 75
            ? Color(red: 0.12, green: 0.84, blue: 0.38)
            : (pts >= 45 ? Color(red: 1.0, green: 0.65, blue: 0.12) : Color.secondary)
        return Text("\(pts) pts")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Exibição bruta do console em tempo real: texto monoespaçado, sem firulas, com cópia e auto-scroll.
private struct LiveConsoleLogView: View {
    @State private var logText: String = ""
    @State private var autoScroll: Bool = true
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(lineCount) linhas")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    autoScroll.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                        Text(autoScroll ? "Auto-rolar" : "Pausado")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(autoScroll ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    UIPasteboard.general.string = logText
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .disabled(logText.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "Aguardando logs do sistema..." : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0.88, green: 0.90, blue: 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                        .id("bottom_anchor")
                }
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .onChange(of: logText) { _, _ in
                    if autoScroll {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom_anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onReceive(timer) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppLogger.logUpdatedNotification)) { _ in reload() }
    }

    private var lineCount: Int {
        logText.isEmpty ? 0 : logText.split(whereSeparator: \.isNewline).count
    }

    private func reload() {
        let text = AppLogger.shared.readLog()
        if text != logText {
            logText = text
        }
    }
}
