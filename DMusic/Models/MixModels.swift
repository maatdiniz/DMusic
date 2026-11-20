import Foundation

nonisolated struct CamelotKey: Codable, Hashable, Sendable {
    let number: Int // 1 a 12
    let letter: Character // "A" (menor) ou "B" (maior)

    var code: String { "\(number)\(letter)" }

    init(number: Int, letter: Character) {
        self.number = number
        self.letter = letter
    }

    init?(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let last = trimmed.last, last == "A" || last == "B",
              let num = Int(trimmed.dropLast()), (1...12).contains(num) else {
            return nil
        }
        self.number = num
        self.letter = last
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = CamelotKey(code: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Camelot key: \(raw)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

nonisolated struct ServerTrackMixInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bpm: Double
    let camelot: String
    let musicalKey: String?
    let energy: Double
    let mixInSec: Double
    let mixOutSec: Double
    let duration: Double?
    let analyzer: String?
    let vibe: [Float]?

    enum CodingKeys: String, CodingKey {
        case id, bpm, camelot, energy, duration, analyzer, vibe
        case musicalKey = "musical_key"
        case mixInSec = "mix_in_sec"
        case mixOutSec = "mix_out_sec"
    }
}

nonisolated struct MixServerTracksResponse: Codable, Sendable {
    let tracks: [ServerTrackMixInfo]
}

nonisolated struct MixServerHealth: Codable, Sendable {
    let status: String
    let totalNavidrome: Int
    let analyzed: Int
    let scanning: Bool
    let analyzer: String

    enum CodingKeys: String, CodingKey {
        case status, analyzed, scanning, analyzer
        case totalNavidrome = "total_navidrome"
    }
}

// MARK: - Catálogo Completo de Efeitos de Mixagem (Volume, EQ, Filtros, Duração)

nonisolated enum AutomixDurationChoice: Int, Codable, CaseIterable, Identifiable, Sendable {
    case auto = 0
    case bars2 = 2
    case bars4 = 4
    case bars8 = 8
    case bars16 = 16

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automático (IA)"
        case .bars2: return "2 compassos"
        case .bars4: return "4 compassos"
        case .bars8: return "8 compassos"
        case .bars16: return "16 compassos"
        }
    }
}

nonisolated enum AutomixVolumeCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case overlap = "overlap"
    case smoothCrossfade = "smooth_crossfade"
    case fadeInFadeOut = "fade_in_fade_out"
    case cutInFadeOut = "cut_in_fade_out"
    case fadeInCutOut = "fade_in_cut_out"
    case centerCut = "center_cut"
    case crossfadeQuickOut = "crossfade_quick_out"
    case fadeIn1BarCutOut = "fade_in_1bar_cut_out"
    case overlap1BarCutOut = "overlap_1bar_cut_out"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automático (Priorizar Sobrepor)"
        case .overlap: return "Sobrepor"
        case .smoothCrossfade: return "Fade cruzado suave"
        case .fadeInFadeOut: return "Fade in fade out"
        case .cutInFadeOut: return "Corte na entrada com fade out"
        case .fadeInCutOut: return "Fade in com corte na saída"
        case .centerCut: return "Corte central"
        case .crossfadeQuickOut: return "Fade cruzado (Fade in com saída rápida)"
        case .fadeIn1BarCutOut: return "Fade in de 1 compasso com corte na saída"
        case .overlap1BarCutOut: return "Sobreposição de 1 compasso com corte na saída"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto, .overlap: return "SOBREPOR"
        case .smoothCrossfade: return "FADE SUAVE"
        case .fadeInFadeOut: return "FADE IN/OUT"
        case .cutInFadeOut: return "CORTE IN"
        case .fadeInCutOut: return "CORTE OUT"
        case .centerCut: return "CORTE CENTRAL"
        case .crossfadeQuickOut: return "SAÍDA RÁPIDA"
        case .fadeIn1BarCutOut: return "FADE 1C + CORTE"
        case .overlap1BarCutOut: return "SOBREP. 1C"
        }
    }
}

nonisolated enum AutomixEQStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case centerBassSwap = "center_bass_swap"
    case endBassSwap = "end_bass_swap"
    case startBassSwap = "start_bass_swap"
    case threeBandTransition = "three_band"
    case quickBassCut = "quick_bass_cut"
    case longBassCut = "long_bass_cut"
    case bassFadeOut = "bass_fade_out"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automático (EQ no meio da transição)"
        case .centerBassSwap: return "Troca de Grave central"
        case .endBassSwap: return "Fim da troca de graves"
        case .startBassSwap: return "Início da troca de graves"
        case .threeBandTransition: return "Transição de 3 bandas"
        case .quickBassCut: return "Corte rápido de graves"
        case .longBassCut: return "Corte longo de graves"
        case .bassFadeOut: return "Fade out de graves"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto, .centerBassSwap: return "EQ CENTRAL"
        case .endBassSwap: return "EQ FIM"
        case .startBassSwap: return "EQ INÍCIO"
        case .threeBandTransition: return "EQ 3 BANDAS"
        case .quickBassCut: return "CORTE GRAVE"
        case .longBassCut: return "GRAVE LONGO"
        case .bassFadeOut: return "FADE GRAVE"
        }
    }
}

nonisolated enum AutomixFilterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case none = "none"
    case lpOut = "lp_out"
    case lpIn = "lp_in"
    case lpInLpOut = "lp_in_lp_out"
    case lpInHpOut = "lp_in_hp_out"
    case hpOut = "hp_out"
    case hpIn = "hp_in"
    case hpInHpOut = "hp_in_hp_out"
    case hpInLpOut = "hp_in_lp_out"
    case partialHpOut = "partial_hp_out"
    case finalNoiseOut = "final_noise_out"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automático (IA)"
        case .none: return "Sem filtro adicional"
        case .lpOut: return "Filtro passa-baixa na saída"
        case .lpIn: return "Filtro passa-baixa na entrada"
        case .lpInLpOut: return "Passa-baixa na entrada + passa-baixa na saída"
        case .lpInHpOut: return "Passa-baixa na entrada + passa-alta na saída"
        case .hpOut: return "Filtro passa-alta na saída"
        case .hpIn: return "Filtro passa-alta na entrada"
        case .hpInHpOut: return "Passa-alta na entrada + passa-alta na saída"
        case .hpInLpOut: return "Passa-alta na entrada + passa-baixa na saída"
        case .partialHpOut: return "Filtro passa-alta parcial na saída"
        case .finalNoiseOut: return "Saída de ruído final (Wash Out)"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "FILTRO IA"
        case .none: return ""
        case .lpOut: return "LP SAÍDA"
        case .lpIn: return "LP ENTRADA"
        case .lpInLpOut: return "LP IN/OUT"
        case .lpInHpOut: return "LP IN • HP OUT"
        case .hpOut: return "HP SAÍDA"
        case .hpIn: return "HP ENTRADA"
        case .hpInHpOut: return "HP IN/OUT"
        case .hpInLpOut: return "HP IN • LP OUT"
        case .partialHpOut: return "HP PARCIAL"
        case .finalNoiseOut: return "WASH OUT"
        }
    }
}

// MARK: - Indicador Discreto de SINC / MIX e Logs do Sistema & Smart Shuffle

nonisolated enum DJStageMode: Equatable, Sendable {
    case idle       // Capa normal (currentSong)
    case ramping    // Rampa de BPM / Cue: Capa A vira Jog A e vai p/ esquerda; Jog B entra na direita
    case mixing     // Mixando: Deck A (esquerda) e Deck B (direita) giram juntos; UI já exibe Música B
    case settling   // Fim da mix: Jog A sai; Jog B vai ao centro, cresce até 100% da capa, freia até 0° e só então vira capa
}

nonisolated struct AutomixIndicatorBadge: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case armed          // Transição armada / aguardando
        case syncUp         // Aumentando BPM (SINC ↑)
        case syncDown       // Abaixando BPM (SINC ↓)
        case syncSteady     // BPM já cravado (SINC •)
        case mixOverlap     // Mixando com Sobrepor + EQ Central
        case mixThreeBand   // Mixando com EQ 3 Bandas
        case mixQuickCut    // Mixando com Corte / Saída Rápida
        case mixFilterWash  // Mixando com Filtro / Wash Out
        case mixFade        // Mixando com Fade
    }

    let text: String
    let icon: String?
    let kind: Kind
}

nonisolated struct SmartShuffleStepLog: Identifiable, Hashable, Sendable {
    let id = UUID()
    let position: Int
    let fromTitle: String
    let toTitle: String
    let toArtist: String
    let bpmFrom: Double
    let bpmTo: Double
    let camelotFrom: String
    let camelotTo: String
    let energyFrom: Double
    let energyTo: Double
    let bpmPoints: Double
    let camelotPoints: Double
    let energyPoints: Double
    let vibePoints: Double
    let vibeSimilarity: Double? // 0.0 a 1.0 (nil quando alguma faixa ainda não tem vetor de vibe)
    let totalScore: Double
    let sourceTag: String // "IA allin1", "Local", "Aleatório"
}

nonisolated struct SmartShuffleRunLog: Identifiable, Hashable, Sendable {
    let id = UUID()
    let timestamp: Date
    let totalTracks: Int
    let aiAnalyzedCount: Int
    let localAnalyzedCount: Int
    let unanalyzedCount: Int
    let beatmatchPairs: Int
    let minScore: Double
    let averageScore: Double
    let steps: [SmartShuffleStepLog]
}

nonisolated struct AutomixEventLog: Identifiable, Hashable, Sendable {
    enum Category: String, Sendable {
        case shuffle = "SHUFFLE"
        case sync = "SINC"
        case mix = "MIX"
        case engine = "ENGINE"
        case server = "SERVIDOR"
    }

    let id = UUID()
    let timestamp: Date
    let category: Category
    let title: String
    let detail: String
}

// MARK: - TransitionPlan JSON (Servidor -> App) conforme especificação

nonisolated struct TransitionPlan: Codable, Sendable {
    var transitionType: String
    var source: String? = nil
    var trackA: TrackATiming
    var trackB: TrackBTiming
    var sync: SyncConfig
    var mix: MixConfig

    enum CodingKeys: String, CodingKey {
        case transitionType = "transition_type"
        case source
        case trackA = "track_a"
        case trackB = "track_b"
        case sync, mix
    }
}

nonisolated struct TrackATiming: Codable, Sendable {
    let id: String
    let bpm: Double
    var rampStartSec: Double
    var mixStartSec: Double
    var mixEndSec: Double
    var section: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, bpm, section
        case rampStartSec = "ramp_start_sec"
        case mixStartSec = "mix_start_sec"
        case mixEndSec = "mix_end_sec"
    }
}

nonisolated struct TrackBTiming: Codable, Sendable {
    let id: String
    let bpm: Double
    var entrySec: Double
    var section: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, bpm, section
        case entrySec = "entry_sec"
    }
}

nonisolated struct SyncConfig: Codable, Sendable {
    var targetRateA: Float
    var initialRateB: Float? = nil
    var rampDurationSec: Double

    enum CodingKeys: String, CodingKey {
        case targetRateA = "target_rate_a"
        case initialRateB = "initial_rate_b"
        case rampDurationSec = "ramp_duration_sec"
    }
}

nonisolated struct MixConfig: Codable, Sendable {
    var durationSec: Double
    var bars: Int? = nil
    var volumeCurve: String? = nil
    var eqStyle: String? = nil
    var filterStyle: String? = nil
    var reverbTail: Bool? = nil
    var eqSwap: EQSwapConfig

    enum CodingKeys: String, CodingKey {
        case durationSec = "duration_sec"
        case bars
        case volumeCurve = "volume_curve"
        case eqStyle = "eq_style"
        case filterStyle = "filter_style"
        case reverbTail = "reverb_tail"
        case eqSwap = "eq_swap"
    }
}

nonisolated struct EQSwapConfig: Codable, Sendable {
    var bassSwapAtProgress: Double
    var bassCutDb: Float

    enum CodingKeys: String, CodingKey {
        case bassSwapAtProgress = "bass_swap_at_progress"
        case bassCutDb = "bass_cut_db"
    }
}
