import Foundation
import Observation

/// Julgamento do usuário sobre uma transição específica na Auditoria.
nonisolated enum TransitionVerdict: String, Codable, CaseIterable, Identifiable, Sendable {
    case approved = "approved"
    case adjusted = "adjusted"
    case needsWork = "needs_work"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approved: return "Perfeita"
        case .adjusted: return "Ajustada"
        case .needsWork: return "Revisar"
        }
    }

    var icon: String {
        switch self {
        case .approved: return "checkmark.circle.fill"
        case .adjusted: return "slider.horizontal.3"
        case .needsWork: return "exclamationmark.triangle.fill"
        }
    }
}

/// Preferência de cauda de reverb na saída para uma receita personalizada.
nonisolated enum TransitionReverbChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case on = "on"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automático"
        case .on: return "Ativar Reverb"
        case .off: return "Sem Reverb"
        }
    }
}

/// Registro histórico de uma transição executada pelo `AutomixAudioEngine`.
nonisolated struct TransitionAuditEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let fromSongId: String
    let fromTitle: String
    let fromArtist: String
    let fromCoverArt: String?
    let toSongId: String
    let toTitle: String
    let toArtist: String
    let toCoverArt: String?
    var fromSong: Song?
    var toSong: Song?

    // Parâmetros exatos que tocaram na transição
    let transitionType: String
    let source: String
    let appliedOverride: Bool
    let bpmA: Double
    let bpmB: Double
    let targetRateA: Float
    let initialRateB: Float
    let mixStartSecA: Double
    let mixEndSecA: Double
    let sectionA: String?
    let entrySecB: Double
    let sectionB: String?
    let bars: Int
    let durationSec: Double
    let volumeCurve: String
    let eqStyle: String
    let filterStyle: String
    let reverbTail: Bool
    let bassSwapAtProgress: Double
    let bassCutDb: Float

    var verdict: TransitionVerdict?

    var pairKey: String {
        TransitionOverride.pairKey(from: fromSongId, to: toSongId)
    }

    var volumeCurveEnum: AutomixVolumeCurve {
        AutomixVolumeCurve(rawValue: volumeCurve) ?? .overlap
    }

    var eqStyleEnum: AutomixEQStyle {
        AutomixEQStyle(rawValue: eqStyle) ?? .centerBassSwap
    }

    var filterStyleEnum: AutomixFilterStyle {
        AutomixFilterStyle(rawValue: filterStyle) ?? .none
    }

    var sourceLabel: String {
        if appliedOverride { return "Receita" }
        return source == "allin1" ? "IA allin1" : "Local"
    }
}

/// Preferência salva pelo usuário para um par específico `(Faixa A → Faixa B)`.
/// Sempre que o Automix armar esse par novamente, estes parâmetros têm prioridade máxima.
nonisolated struct TransitionOverride: Codable, Identifiable, Hashable, Sendable {
    var id: String { pairKey }
    let pairKey: String
    let fromSongId: String
    let toSongId: String
    var fromTitle: String
    var fromArtist: String
    var fromCoverArt: String?
    var toTitle: String
    var toArtist: String
    var toCoverArt: String?
    var fromSong: Song?
    var toSong: Song?

    var verdict: TransitionVerdict
    var durationChoice: AutomixDurationChoice
    var volumeCurve: AutomixVolumeCurve
    var eqStyle: AutomixEQStyle
    var filterStyle: AutomixFilterStyle
    var reverbChoice: TransitionReverbChoice
    /// Deslocamento em compassos inteiros aplicado ao ponto de saída da Faixa A (`mixStartSec`).
    var mixStartOffsetBars: Int
    /// Deslocamento em compassos inteiros aplicado ao ponto de entrada da Faixa B (`entrySec`).
    var entryOffsetBars: Int
    var note: String
    var updatedAt: Date

    static func pairKey(from idA: String, to idB: String) -> String {
        "\(idA)->\(idB)"
    }

    /// Indica se há pelo menos um parâmetro alterado em relação ao padrão automático.
    var hasParameterCustomizations: Bool {
        durationChoice != .auto
            || volumeCurve != .auto
            || eqStyle != .auto
            || filterStyle != .auto
            || reverbChoice != .auto
            || mixStartOffsetBars != 0
            || entryOffsetBars != 0
    }

    /// Resumo curto das personalizações ativas para exibição em listas.
    var summaryTags: [String] {
        var tags: [String] = []
        if durationChoice != .auto { tags.append("\(durationChoice.rawValue) comp.") }
        if volumeCurve != .auto { tags.append(volumeCurve.shortLabel) }
        if eqStyle != .auto { tags.append(eqStyle.shortLabel) }
        if filterStyle != .auto {
            let label = filterStyle.shortLabel
            tags.append(label.isEmpty ? "SEM FILTRO" : label)
        }
        if reverbChoice == .on { tags.append("REVERB ON") }
        if reverbChoice == .off { tags.append("REVERB OFF") }
        if mixStartOffsetBars != 0 {
            let sign = mixStartOffsetBars > 0 ? "+" : ""
            tags.append("SAÍDA \(sign)\(mixStartOffsetBars)c")
        }
        if entryOffsetBars != 0 {
            let sign = entryOffsetBars > 0 ? "+" : ""
            tags.append("ENTRADA \(sign)\(entryOffsetBars)c")
        }
        return tags
    }
}

private nonisolated struct TransitionAuditPersistence: Codable, Sendable {
    var history: [TransitionAuditEntry]
    var overrides: [String: TransitionOverride]
}

/// Armazena localmente o histórico de transições executadas e as receitas personalizadas por par `(A → B)`.
@Observable
@MainActor
final class TransitionAuditStore {
    private(set) var history: [TransitionAuditEntry] = []
    private(set) var overrides: [String: TransitionOverride] = [:]

    private let maxHistoryCount = 200
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("DMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("transition_audit.json")
        loadFromDisk()
    }

    var sortedOverrides: [TransitionOverride] {
        overrides.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func override(from idA: String, to idB: String) -> TransitionOverride? {
        overrides[TransitionOverride.pairKey(from: idA, to: idB)]
    }

    func recordTransition(from songA: Song, to songB: Song, plan: TransitionPlan, appliedOverride: Bool) {
        let now = Date()
        // Evita duplicação caso o mesmo par dispare duas notificações em menos de 3 segundos
        if let last = history.first,
           last.fromSongId == songA.id,
           last.toSongId == songB.id,
           now.timeIntervalSince(last.timestamp) < 3.0 {
            return
        }

        let barSecA = 4.0 * 60.0 / max(plan.trackA.bpm, 65.0)
        let inferredBars = plan.mix.bars
            ?? max(2, Int(((plan.trackA.mixEndSec - plan.trackA.mixStartSec) / barSecA).rounded()))
        let existingVerdict = override(from: songA.id, to: songB.id)?.verdict

        let entry = TransitionAuditEntry(
            id: UUID(),
            timestamp: now,
            fromSongId: songA.id,
            fromTitle: songA.title,
            fromArtist: songA.displayArtist ?? songA.artist ?? "Artista desconhecido",
            fromCoverArt: songA.coverArt,
            toSongId: songB.id,
            toTitle: songB.title,
            toArtist: songB.displayArtist ?? songB.artist ?? "Artista desconhecido",
            toCoverArt: songB.coverArt,
            fromSong: songA,
            toSong: songB,
            transitionType: plan.transitionType,
            source: plan.source ?? "local",
            appliedOverride: appliedOverride,
            bpmA: plan.trackA.bpm,
            bpmB: plan.trackB.bpm,
            targetRateA: plan.sync.targetRateA,
            initialRateB: plan.sync.initialRateB ?? 1.0,
            mixStartSecA: plan.trackA.mixStartSec,
            mixEndSecA: plan.trackA.mixEndSec,
            sectionA: plan.trackA.section,
            entrySecB: plan.trackB.entrySec,
            sectionB: plan.trackB.section,
            bars: inferredBars,
            durationSec: plan.mix.durationSec,
            volumeCurve: plan.mix.volumeCurve ?? AutomixVolumeCurve.overlap.rawValue,
            eqStyle: plan.mix.eqStyle ?? AutomixEQStyle.centerBassSwap.rawValue,
            filterStyle: plan.mix.filterStyle ?? AutomixFilterStyle.none.rawValue,
            reverbTail: plan.mix.reverbTail ?? false,
            bassSwapAtProgress: plan.mix.eqSwap.bassSwapAtProgress,
            bassCutDb: plan.mix.eqSwap.bassCutDb,
            verdict: existingVerdict
        )

        history.insert(entry, at: 0)
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
        saveToDisk()
    }

    func saveOverride(_ override: TransitionOverride, entryId: UUID? = nil) {
        var updated = override
        updated.updatedAt = Date()
        overrides[updated.pairKey] = updated

        if let entryId, let idx = history.firstIndex(where: { $0.id == entryId }) {
            history[idx].verdict = updated.verdict
        } else {
            for idx in history.indices where history[idx].pairKey == updated.pairKey {
                history[idx].verdict = updated.verdict
            }
        }
        saveToDisk()
    }

    func deleteOverride(pairKey: String) {
        overrides.removeValue(forKey: pairKey)
        for idx in history.indices where history[idx].pairKey == pairKey {
            history[idx].verdict = nil
        }
        saveToDisk()
    }

    func deleteHistoryEntry(id: UUID) {
        history.removeAll { $0.id == id }
        saveToDisk()
    }

    func clearHistory() {
        history.removeAll()
        saveToDisk()
    }

    func clearOverrides() {
        overrides.removeAll()
        for idx in history.indices {
            history[idx].verdict = nil
        }
        saveToDisk()
    }

    // MARK: - Persistência

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(TransitionAuditPersistence.self, from: data) else {
            return
        }
        history = decoded.history
        overrides = decoded.overrides
    }

    private func saveToDisk() {
        let snapshot = TransitionAuditPersistence(history: history, overrides: overrides)
        let targetURL = fileURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: targetURL, options: .atomic)
        }
    }
}
