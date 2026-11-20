import Foundation
import Observation

nonisolated enum VolumeCompensationLevel: String, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Desligada"
        case .low: return "Baixo (Suave)"
        case .medium: return "Médio (Equilibrado)"
        case .high: return "Alto (Máximo Impacto)"
        }
    }

    var note: String {
        switch self {
        case .off:
            return "Reproduz cada música no volume original do arquivo, sem compensação de ganho."
        case .low:
            return "Baixo (-16 dBFS): preserva ao máximo a dinâmica original, corrigindo apenas diferenças grandes entre faixas. Ideal para fones e audição Hi‑Fi."
        case .medium:
            return "Médio (-14 dBFS): padrão equilibrado para streaming e mixagem DJ. Nivela bem faixas antigas e modernas mantendo margem limpa contra distorção."
        case .high:
            return "Alto (-11 dBFS): aproxima faixas mais baixas do volume máximo das produções modernas (protegido contra clipping). Pode reduzir a sensação de dinâmica em músicas muito calmas."
        }
    }

    var targetDBFS: Float {
        switch self {
        case .off: return -14.0
        case .low: return -16.0
        case .medium: return -14.0
        case .high: return -11.0
        }
    }

    var maxBoostDB: Float {
        switch self {
        case .off: return 0.0
        case .low: return 3.5
        case .medium: return 6.0
        case .high: return 9.0
        }
    }

    var maxCutDB: Float {
        switch self {
        case .off: return 0.0
        case .low: return -8.0
        case .medium: return -10.0
        case .high: return -12.0
        }
    }
}

/// Ajustes gerais do app (persistidos em UserDefaults).
@Observable
@MainActor
final class CacheSettings {
    /// 0 = desativado
    static let recentOptionsMB = [0, 500, 1000, 2000, 5000, 10000]
    /// 0 = original (sem transcodificação)
    static let bitrateOptions = [0, 320, 256, 192, 128]

    var recentLimitMB: Int { didSet { save(recentLimitMB, "recent_cache_mb") } }
    var wifiBitrate: Int { didSet { save(wifiBitrate, "wifi_bitrate") } }
    var cellularBitrate: Int { didSet { save(cellularBitrate, "cellular_bitrate") } }
    var cacheOnlyWifi: Bool { didSet { save(cacheOnlyWifi, "cache_only_wifi") } }
    var resumePlayback: Bool { didSet { save(resumePlayback, "resume_playback") } }
    var volumeCompensation: VolumeCompensationLevel { didSet { save(volumeCompensation.rawValue, "volume_compensation") } }

    init() {
        let d = UserDefaults.standard
        recentLimitMB = d.object(forKey: "recent_cache_mb") as? Int ?? 1000
        wifiBitrate = d.object(forKey: "wifi_bitrate") as? Int ?? 0
        cellularBitrate = d.object(forKey: "cellular_bitrate") as? Int ?? 0
        cacheOnlyWifi = d.object(forKey: "cache_only_wifi") as? Bool ?? true
        resumePlayback = d.object(forKey: "resume_playback") as? Bool ?? true
        volumeCompensation = VolumeCompensationLevel(rawValue: d.string(forKey: "volume_compensation") ?? "") ?? .off
    }

    private func save(_ v: Any, _ key: String) { UserDefaults.standard.set(v, forKey: key) }

    static func label(_ mb: Int) -> String {
        if mb == 0 { return "Desativado" }
        return mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB"
    }

    static func bitrateLabel(_ kbps: Int) -> String { kbps == 0 ? "Original (sem perdas)" : "\(kbps) kbps (MP3)" }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
