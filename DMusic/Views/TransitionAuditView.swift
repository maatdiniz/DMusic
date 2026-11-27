import SwiftUI

/// Tela principal de Auditoria de Transições (Histórico de mixagens executadas + Receitas salvas por par).
struct TransitionAuditView: View {
    @Environment(TransitionAuditStore.self) private var auditStore
    @State private var selectedTab = 0
    @State private var confirmClearHistory = false
    @State private var confirmClearOverrides = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Seção", selection: $selectedTab) {
                Text("Histórico (\(auditStore.history.count))").tag(0)
                Text("Receitas (\(auditStore.overrides.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if selectedTab == 0 {
                historyListView
            } else {
                overridesListView
            }
        }
        .background(DarkSheetTheme.background.ignoresSafeArea())
        .navigationTitle("Auditoria de Mix")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectedTab == 0 {
                    Button(role: .destructive) {
                        confirmClearHistory = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(auditStore.history.isEmpty)
                } else {
                    Button(role: .destructive) {
                        confirmClearOverrides = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(auditStore.overrides.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Limpar histórico de transições?",
            isPresented: $confirmClearHistory,
            titleVisibility: .visible
        ) {
            Button("Limpar histórico", role: .destructive) {
                auditStore.clearHistory()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Suas receitas personalizadas salvas não serão apagadas.")
        }
        .confirmationDialog(
            "Remover todas as receitas salvas?",
            isPresented: $confirmClearOverrides,
            titleVisibility: .visible
        ) {
            Button("Remover receitas", role: .destructive) {
                auditStore.clearOverrides()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todas as transições voltarão a seguir o planejamento automático.")
        }
    }

    @ViewBuilder
    private var historyListView: some View {
        if auditStore.history.isEmpty {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.top, 56)
                    Text("Nenhuma transição registrada ainda")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Sempre que o Automix executar uma transição entre duas faixas, todos os parâmetros usados aparecem aqui para você auditar e ajustar como prefere na próxima vez.")
                        .font(.subheadline)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(auditStore.history) { entry in
                        let savedOverride = auditStore.override(from: entry.fromSongId, to: entry.toSongId)
                        NavigationLink {
                            TransitionAuditDetailView(entry: entry)
                        } label: {
                            TransitionHistoryCard(entry: entry, savedOverride: savedOverride)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var overridesListView: some View {
        let items = auditStore.sortedOverrides
        if items.isEmpty {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.top, 56)
                    Text("Nenhuma receita salva")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Selecione uma transição no Histórico e salve os ajustes desejados. Quando esse par tocar novamente, o Automix aplicará sua preferência automaticamente.")
                        .font(.subheadline)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        NavigationLink {
                            TransitionAuditDetailView(overrideItem: item)
                        } label: {
                            TransitionOverrideCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - Cards da Lista

private struct TransitionHistoryCard: View {
    let entry: TransitionAuditEntry
    let savedOverride: TransitionOverride?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DualMiniCovers(coverA: entry.fromCoverArt, coverB: entry.toCoverArt)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(entry.fromTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Text(entry.toTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    Text("\(entry.fromArtist) → \(entry.toArtist)")
                        .font(.caption)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(Self.relativeTimestamp(entry.timestamp))
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.42))
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text("\(AuditFormat.mmss(entry.mixStartSecA)) → \(AuditFormat.mmss(entry.entrySecB))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.32))
            }

            HStack(spacing: 6) {
                AuditPill(
                    text: entry.sourceLabel.uppercased(),
                    tint: entry.appliedOverride
                        ? Color(red: 0.16, green: 0.62, blue: 1.0)
                        : (entry.source == "allin1" ? Color(red: 0.14, green: 0.82, blue: 0.48) : Color.white.opacity(0.55))
                )
                AuditPill(text: "\(entry.bars) COMP.", tint: Color.white.opacity(0.75))
                AuditPill(text: entry.volumeCurveEnum.shortLabel, tint: Color.white.opacity(0.7))
                AuditPill(text: entry.eqStyleEnum.shortLabel, tint: Color.white.opacity(0.7))

                Spacer(minLength: 0)

                if let verdict = savedOverride?.verdict ?? entry.verdict {
                    VerdictBadge(verdict: verdict)
                }
            }
        }
        .padding(12)
        .background(DarkSheetTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    savedOverride?.hasParameterCustomizations == true
                        ? Color(red: 0.16, green: 0.62, blue: 1.0).opacity(0.35)
                        : DarkSheetTheme.cardStroke,
                    lineWidth: 0.8
                )
        )
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct TransitionOverrideCard: View {
    let item: TransitionOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DualMiniCovers(coverA: item.fromCoverArt, coverB: item.toCoverArt)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(item.fromTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Text(item.toTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Text("\(item.fromArtist) → \(item.toArtist)")
                        .font(.caption)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                VerdictBadge(verdict: item.verdict)
            }

            let tags = item.summaryTags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            AuditPill(text: tag, tint: Color(red: 0.22, green: 0.66, blue: 1.0))
                        }
                    }
                }
            } else {
                Text("Mantém os parâmetros automáticos (somente avaliação salva)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("“\(item.note)”")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(DarkSheetTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DarkSheetTheme.cardStroke, lineWidth: 0.7)
        )
    }
}

// MARK: - Tela de Detalhe, Julgamento e Ajuste da Próxima Transição

struct TransitionAuditDetailView: View {
    @Environment(TransitionAuditStore.self) private var auditStore
    @Environment(AudioPlayerManager.self) private var player
    @Environment(\.dismiss) private var dismiss

    let entry: TransitionAuditEntry?
    let initialOverride: TransitionOverride?

    @State private var verdict: TransitionVerdict = .adjusted
    @State private var durationChoice: AutomixDurationChoice = .auto
    @State private var volumeCurve: AutomixVolumeCurve = .auto
    @State private var eqStyle: AutomixEQStyle = .auto
    @State private var filterStyle: AutomixFilterStyle = .auto
    @State private var reverbChoice: TransitionReverbChoice = .auto
    @State private var mixStartOffsetBars: Int = 0
    @State private var entryOffsetBars: Int = 0
    @State private var note: String = ""
    @State private var didLoadInitialState = false
    @State private var showSavedBanner = false

    init(entry: TransitionAuditEntry) {
        self.entry = entry
        self.initialOverride = nil
    }

    init(overrideItem: TransitionOverride) {
        self.entry = nil
        self.initialOverride = overrideItem
    }

    private var fromSongId: String { entry?.fromSongId ?? initialOverride?.fromSongId ?? "" }
    private var toSongId: String { entry?.toSongId ?? initialOverride?.toSongId ?? "" }
    private var fromTitle: String { entry?.fromTitle ?? initialOverride?.fromTitle ?? "" }
    private var fromArtist: String { entry?.fromArtist ?? initialOverride?.fromArtist ?? "" }
    private var fromCoverArt: String? { entry?.fromCoverArt ?? initialOverride?.fromCoverArt }
    private var toTitle: String { entry?.toTitle ?? initialOverride?.toTitle ?? "" }
    private var toArtist: String { entry?.toArtist ?? initialOverride?.toArtist ?? "" }
    private var toCoverArt: String? { entry?.toCoverArt ?? initialOverride?.toCoverArt }
    private var fromSong: Song? { entry?.fromSong ?? initialOverride?.fromSong }
    private var toSong: Song? { entry?.toSong ?? initialOverride?.toSong }
    private var pairKey: String { TransitionOverride.pairKey(from: fromSongId, to: toSongId) }
    private var existingOverride: TransitionOverride? { auditStore.override(from: fromSongId, to: toSongId) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                pairHeaderCard

                if let entry {
                    executedParametersCard(entry)
                }

                verdictCard
                nextTimeRecipeCard
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .background(DarkSheetTheme.background.ignoresSafeArea())
        .navigationTitle("Auditar Transição")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadInitialValuesIfNeeded)
        .overlay(alignment: .bottom) {
            if showSavedBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.14, green: 0.86, blue: 0.46))
                    Text("Preferência salva para a próxima mixagem")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Seções

    private var pairHeaderCard: some View {
        DarkCardSection("Par de Faixas") {
            HStack(spacing: 12) {
                VStack(spacing: 6) {
                    CoverArtView(coverArt: fromCoverArt, size: 200, cornerRadius: 10)
                        .frame(width: 68, height: 68)
                    Text(fromTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(fromArtist)
                        .font(.caption2)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 1.0))
                    if let entry {
                        Text("\(Int(entry.bpmA.rounded()))→\(Int(entry.bpmB.rounded()))")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.65))
                        Text("BPM")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }

                VStack(spacing: 6) {
                    CoverArtView(coverArt: toCoverArt, size: 200, cornerRadius: 10)
                        .frame(width: 68, height: 68)
                    Text(toTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(toArtist)
                        .font(.caption2)
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
        }
    }

    private func executedParametersCard(_ entry: TransitionAuditEntry) -> some View {
        let pct = (entry.targetRateA - 1.0) * 100.0
        let pitchText = abs(pct) < 0.2 ? "Cravado (0%)" : String(format: "%+.1f%%", pct)
        let secA = entry.sectionA.map { " (\($0))" } ?? ""
        let secB = entry.sectionB.map { " (\($0))" } ?? ""
        let modeText = entry.transitionType == "beatmatch" ? "Beatmatch" : "Crossfade"

        return DarkCardSection(
            "Parâmetros usados nesta transição",
            footer: "Estes foram os valores exatos executados pelo motor de áudio naquela passagem."
        ) {
            DarkLabeledRow(title: "Origem", value: "\(entry.sourceLabel) • \(modeText)")
            DarkCardDivider()
            DarkLabeledRow(title: "Duração", value: "\(entry.bars) compassos (\(String(format: "%.1fs", entry.durationSec)))")
            DarkCardDivider()
            DarkLabeledRow(title: "Saída da Faixa A", value: "\(AuditFormat.mmss(entry.mixStartSecA))\(secA)")
            DarkCardDivider()
            DarkLabeledRow(title: "Entrada da Faixa B", value: "\(AuditFormat.mmss(entry.entrySecB))\(secB)")
            DarkCardDivider()
            DarkLabeledRow(title: "Sincronia de BPM", value: pitchText)
            DarkCardDivider()
            DarkLabeledRow(title: "Curva de Volume", value: entry.volumeCurveEnum.title)
            DarkCardDivider()
            DarkLabeledRow(title: "Estilo de EQ", value: "\(entry.eqStyleEnum.title) (\(Int(entry.bassCutDb)) dB)")
            DarkCardDivider()
            DarkLabeledRow(title: "Filtro Adicional", value: entry.filterStyleEnum.title)
            DarkCardDivider()
            DarkLabeledRow(title: "Reverb na Saída", value: entry.reverbTail ? "Ativo" : "Desligado")
        }
    }

    private var verdictCard: some View {
        DarkCardSection("Seu Julgamento") {
            HStack(spacing: 8) {
                ForEach(TransitionVerdict.allCases) { option in
                    let isSelected = verdict == option
                    let accent = verdictColor(option)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            verdict = option
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: option.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(option.title)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(isSelected ? .white : Color.white.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isSelected ? accent.opacity(0.28) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isSelected ? accent : Color.white.opacity(0.08), lineWidth: isSelected ? 1.2 : 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private var nextTimeRecipeCard: some View {
        let previewOutA: String? = entry.map { e in
            let barSec = 4.0 * 60.0 / max(e.bpmA, 65.0)
            let shifted = max(0.0, e.mixStartSecA + Double(mixStartOffsetBars) * barSec)
            return AuditFormat.mmss(shifted)
        }
        let previewInB: String? = entry.map { e in
            let barSec = 4.0 * 60.0 / max(e.bpmB, 65.0)
            let shifted = max(0.0, e.entrySecB + Double(entryOffsetBars) * barSec)
            return AuditFormat.mmss(shifted)
        }

        return DarkCardSection(
            "Como aplicar na próxima vez (A → B)",
            footer: "Deixe em \"Automático\" o que quiser manter no padrão do algoritmo. Tudo o que você alterar aqui terá prioridade máxima quando essas faixas voltarem a se encontrar."
        ) {
            DarkMenuPickerRow(
                title: "Duração",
                selection: $durationChoice,
                valueLabel: durationChoice.title,
                options: AutomixDurationChoice.allCases.map { ($0, $0.title) }
            )
            DarkCardDivider()
            DarkMenuPickerRow(
                title: "Curva de Volume",
                selection: $volumeCurve,
                valueLabel: volumeCurve.title,
                options: AutomixVolumeCurve.allCases.map { ($0, $0.title) }
            )
            DarkCardDivider()
            DarkMenuPickerRow(
                title: "Estilo de EQ",
                selection: $eqStyle,
                valueLabel: eqStyle.title,
                options: AutomixEQStyle.allCases.map { ($0, $0.title) }
            )
            DarkCardDivider()
            DarkMenuPickerRow(
                title: "Filtro Adicional",
                selection: $filterStyle,
                valueLabel: filterStyle.title,
                options: AutomixFilterStyle.allCases.map { ($0, $0.title) }
            )
            DarkCardDivider()
            DarkMenuPickerRow(
                title: "Reverb na Saída",
                selection: $reverbChoice,
                valueLabel: reverbChoice.title,
                options: TransitionReverbChoice.allCases.map { ($0, $0.title) }
            )
            DarkCardDivider()
            BarOffsetRow(
                title: "Ponto de Saída (Faixa A)",
                subtitle: previewOutA.map { "Novo ponto estimado: \($0)" },
                bars: $mixStartOffsetBars
            )
            DarkCardDivider()
            BarOffsetRow(
                title: "Ponto de Entrada (Faixa B)",
                subtitle: previewInB.map { "Novo ponto estimado: \($0)" },
                bars: $entryOffsetBars
            )
            DarkCardDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Observação (opcional)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DarkSheetTheme.secondaryText)
                TextField("Ex: Grave embolou no refrão, antecipar saída...", text: $note, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2...4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 10) {
            Button {
                saveCurrentRecipe()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Salvar para a próxima vez")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(red: 0.04, green: 0.52, blue: 1.0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if let sA = fromSong, let sB = toSong {
                Button {
                    saveCurrentRecipe()
                    player.auditionTransition(from: sA, to: sB)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                        Text("Salvar e Testar Mix Agora")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }

            if existingOverride != nil {
                Button(role: .destructive) {
                    auditStore.deleteOverride(pairKey: pairKey)
                    player.reprepareCurrentPairIfMatching(from: fromSongId, to: toSongId)
                    if entry == nil {
                        dismiss()
                    } else {
                        resetToDefaults()
                    }
                } label: {
                    Text("Remover receita salva (voltar ao automático)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.38))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func loadInitialValuesIfNeeded() {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true

        if let saved = existingOverride ?? initialOverride {
            verdict = saved.verdict
            durationChoice = saved.durationChoice
            volumeCurve = saved.volumeCurve
            eqStyle = saved.eqStyle
            filterStyle = saved.filterStyle
            reverbChoice = saved.reverbChoice
            mixStartOffsetBars = saved.mixStartOffsetBars
            entryOffsetBars = saved.entryOffsetBars
            note = saved.note
        } else if let entry {
            verdict = entry.verdict ?? .adjusted
            durationChoice = .auto
            volumeCurve = .auto
            eqStyle = .auto
            filterStyle = .auto
            reverbChoice = .auto
            mixStartOffsetBars = 0
            entryOffsetBars = 0
            note = ""
        }
    }

    private func resetToDefaults() {
        verdict = .adjusted
        durationChoice = .auto
        volumeCurve = .auto
        eqStyle = .auto
        filterStyle = .auto
        reverbChoice = .auto
        mixStartOffsetBars = 0
        entryOffsetBars = 0
        note = ""
    }

    private func saveCurrentRecipe() {
        let model = TransitionOverride(
            pairKey: pairKey,
            fromSongId: fromSongId,
            toSongId: toSongId,
            fromTitle: fromTitle,
            fromArtist: fromArtist,
            fromCoverArt: fromCoverArt,
            toTitle: toTitle,
            toArtist: toArtist,
            toCoverArt: toCoverArt,
            fromSong: fromSong,
            toSong: toSong,
            verdict: verdict,
            durationChoice: durationChoice,
            volumeCurve: volumeCurve,
            eqStyle: eqStyle,
            filterStyle: filterStyle,
            reverbChoice: reverbChoice,
            mixStartOffsetBars: mixStartOffsetBars,
            entryOffsetBars: entryOffsetBars,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: Date()
        )
        auditStore.saveOverride(model, entryId: entry?.id)
        player.reprepareCurrentPairIfMatching(from: fromSongId, to: toSongId)

        withAnimation(.easeOut(duration: 0.22)) {
            showSavedBanner = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation(.easeIn(duration: 0.25)) {
                showSavedBanner = false
            }
        }
    }

    private func verdictColor(_ v: TransitionVerdict) -> Color {
        switch v {
        case .approved: return Color(red: 0.14, green: 0.84, blue: 0.46)
        case .adjusted: return Color(red: 0.14, green: 0.58, blue: 1.0)
        case .needsWork: return Color(red: 1.0, green: 0.58, blue: 0.18)
        }
    }
}

// MARK: - Componentes Visuais Auxiliares

private struct BarOffsetRow: View {
    let title: String
    let subtitle: String?
    @Binding var bars: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DarkSheetTheme.secondaryText)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    bars = max(-16, bars - 2)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(bars <= -16)

                Text(offsetLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(bars == 0 ? DarkSheetTheme.secondaryText : Color(red: 0.22, green: 0.66, blue: 1.0))
                    .frame(minWidth: 58)

                Button {
                    bars = min(16, bars + 2)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(bars >= 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var offsetLabel: String {
        if bars == 0 { return "Padrão" }
        return bars > 0 ? "+\(bars) comp." : "\(bars) comp."
    }
}

private struct DualMiniCovers: View {
    let coverA: String?
    let coverB: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CoverArtView(coverArt: coverA, size: 120, cornerRadius: 6)
                .frame(width: 36, height: 36)
                .offset(x: -7, y: -5)
            CoverArtView(coverArt: coverB, size: 120, cornerRadius: 6)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(DarkSheetTheme.background, lineWidth: 1.5)
                )
                .offset(x: 7, y: 5)
        }
        .frame(width: 52, height: 48)
    }
}

private struct AuditPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct VerdictBadge: View {
    let verdict: TransitionVerdict

    private var color: Color {
        switch verdict {
        case .approved: return Color(red: 0.14, green: 0.84, blue: 0.46)
        case .adjusted: return Color(red: 0.18, green: 0.64, blue: 1.0)
        case .needsWork: return Color(red: 1.0, green: 0.58, blue: 0.18)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: verdict.icon)
                .font(.system(size: 10, weight: .bold))
            Text(verdict.title)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
    }
}

private enum AuditFormat {
    static func mmss(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
