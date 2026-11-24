"""
Pós-processamento da análise allin1 (usado pela análise completa e pelo modo --reprocess):

  - Grade de batidas de tempo constante (como o rekordbox): regressão robusta sobre as batidas do allin1
    (que vêm quantizadas em 10 ms e se perdem em breakdowns), refinamento de fase pelo ataque real
    (onset de banda larga, ±35 ms) e tempo 1 escolhido por votação dos downbeats do allin1.
  - Seções encaixadas no downbeat mais próximo.
  - `bar_beat` (presença de batida por compasso) na faixa inteira.
  - Energia independente do volume do master (normalizada por percentil da biblioteca).
  - Tom: tag do arquivo (initialkey/TKEY, curada por Beatport/Mixed In Key) ou madmom CNN.
  - `bar_vocal` (presença de voz por compasso) a partir do stem de voz do demucs, quando disponível.
"""

import json
import re
import subprocess
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

ANALYSIS_VERSION = 2

KEY_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
CAMELOT_MAJOR = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
CAMELOT_MINOR = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]
NOTE_INDEX = {"C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "F": 5, "F#": 6, "GB": 6,
              "G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11, "CB": 11, "FB": 4, "E#": 5, "B#": 0}
FFPROBE = "/opt/homebrew/bin/ffprobe"

# Limites para considerar a faixa de tempo constante (música eletrônica/produzida em grade)
CONST_INLIER_TOL = 0.035      # batida a até 35 ms da grade conta como "na grade"
CONST_MIN_INLIERS = 0.80      # 80% das batidas na grade
CONST_MAX_RESIDUAL = 0.018    # erro RMS das batidas na grade ≤ 18 ms
PHASE_MAX_SHIFT = 0.035       # refinamento de fase limitado a ±35 ms


# --------------------------------------------------------------------------- grade

def _longest_clean_run(beats: np.ndarray) -> Tuple[int, int]:
    ibi = np.diff(beats)
    med = float(np.median(ibi))
    ok = np.abs(ibi - med) <= 0.08 * med
    best, best_rng, cur, start = 0, (0, len(beats) - 1), 0, 0
    for i, good in enumerate(ok):
        if good:
            if cur == 0:
                start = i
            cur += 1
            if cur > best:
                best, best_rng = cur, (start, i + 1)
        else:
            cur = 0
    return best_rng


def _fit_constant_grid(beats: np.ndarray) -> Tuple[float, float, np.ndarray, float]:
    """Ajusta t = t0 + k·P por regressão iterativa só com batidas próximas da grade. Retorna (P, t0, inliers, rms)."""
    lo, hi = _longest_clean_run(beats)
    seg = beats[lo:hi + 1]
    k = np.arange(len(seg))
    period, t0 = np.polyfit(k, seg, 1)
    t0 = t0 - lo * period  # índice 0 = primeira batida do allin1
    inl = np.zeros(len(beats), dtype=bool)
    for _ in range(4):
        idx = np.round((beats - t0) / period)
        resid = beats - (t0 + idx * period)
        inl = np.abs(resid) <= CONST_INLIER_TOL
        if inl.sum() < 8:
            break
        period, t0 = np.polyfit(idx[inl], beats[inl], 1)
    idx = np.round((beats - t0) / period)
    resid = beats - (t0 + idx * period)
    inl = np.abs(resid) <= CONST_INLIER_TOL
    rms = float(np.sqrt(np.mean(resid[inl] ** 2))) if inl.any() else 1.0
    return float(period), float(t0), inl, rms


def _onset_phase_offset(y: np.ndarray, sr: int, grid: np.ndarray) -> Optional[float]:
    """Desvio médio (s) entre a grade e o ataque real (onset de banda larga, log), com interpolação parabólica."""
    import librosa

    hop = 64
    fps = sr / hop
    on = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop, n_fft=512, lag=1, max_size=1)
    w = int(round(0.06 * fps))
    prof = np.zeros(2 * w + 1)
    n = 0
    for b in grid:
        i = int(round(b * fps))
        if i - w >= 0 and i + w < len(on):
            prof += on[i - w:i + w + 1]
            n += 1
    if n < 16:
        return None
    p = int(np.argmax(prof))
    if prof[p] < 1.5 * (np.median(prof) + 1e-9) or p in (0, len(prof) - 1):
        return None
    a, b, c = prof[p - 1], prof[p], prof[p + 1]
    frac = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
    off = (p - w + frac) / fps
    return off if abs(off) <= PHASE_MAX_SHIFT else None


def _minmax(v: np.ndarray) -> np.ndarray:
    span = float(v.max() - v.min())
    return (v - v.min()) / span if span > 1e-12 else np.zeros_like(v)


def _share(v: np.ndarray) -> np.ndarray:
    total = float(v.sum())
    return v / total if total > 0 else np.zeros_like(v)


def _bar_phase_scores(
    t0: float,
    period: float,
    ks: np.ndarray,
    raw_db: np.ndarray,
    segments: Optional[List[dict]],
    y: Optional[np.ndarray],
    sr: Optional[int],
) -> Tuple[int, Dict[str, List[float]]]:
    """Escolhe qual das 4 batidas é o tempo 1 somando quatro critérios (medido em 86 faixas: cada um sozinho
    concorda com os outros em 72–88%; o allin1 troca a contagem no meio em ~7% das faixas):
      - voto dos downbeats do allin1          (peso 1.0)
      - inícios de seção do allin1            (peso 1.0)
      - mudança do baixo (<250 Hz) por compasso  (peso 0.8)
      - mudança de timbre (MFCC) por compasso    (peso 0.8)
    """
    votes = np.zeros(4)
    for d in raw_db:
        k = int(round((d - t0) / period))
        if abs(d - (t0 + k * period)) <= CONST_INLIER_TOL:
            votes[k % 4] += 1
    seg = np.zeros(4)
    for s in segments or []:
        if str(s.get("label", "")) not in ("start", "end") and float(s.get("start", 0.0)) > 1.0:
            seg[int(round((float(s["start"]) - t0) / period)) % 4] += 1

    mfcc_nov, bass_nov = np.zeros(4), np.zeros(4)
    if y is not None and sr:
        import librosa
        hop = 512
        S = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
        f = librosa.fft_frequencies(sr=sr, n_fft=2048)
        mfcc = librosa.feature.mfcc(S=librosa.power_to_db(librosa.feature.melspectrogram(S=S ** 2, sr=sr)), n_mfcc=13)
        bass = librosa.feature.chroma_stft(S=S * (f[:, None] < 250), sr=sr)
        frames = librosa.time_to_frames(t0 + ks * period, sr=sr, hop_length=hop)
        win = int(4 * period * sr / hop)
        cnt = np.zeros(4)
        for k, a in zip(ks, frames):
            if a - win < 0 or a + win > S.shape[1]:
                continue
            mfcc_nov[k % 4] += np.linalg.norm(mfcc[:, a:a + win].mean(1) - mfcc[:, a - win:a].mean(1))
            bass_nov[k % 4] += np.linalg.norm(bass[:, a:a + win].mean(1) - bass[:, a - win:a].mean(1))
            cnt[k % 4] += 1
        mfcc_nov /= np.maximum(cnt, 1)
        bass_nov /= np.maximum(cnt, 1)

    total = 1.0 * _share(votes) + 1.0 * _share(seg) + 0.8 * _minmax(bass_nov) + 0.8 * _minmax(mfcc_nov)
    phase = int(np.argmax(total)) if total.max() > 0 else int(ks[0] % 4)
    detail = {"votes": votes.tolist(), "sections": seg.tolist(),
              "bass": [round(float(x), 4) for x in bass_nov], "timbre": [round(float(x), 3) for x in mfcc_nov],
              "total": [round(float(x), 3) for x in total]}
    return phase, detail


def regularize_grid(
    beats: List[float],
    downbeats: List[float],
    duration: float,
    y: Optional[np.ndarray] = None,
    sr: Optional[int] = None,
    segments: Optional[List[dict]] = None,
) -> Dict:
    """Grade de tempo constante cobrindo a faixa inteira (ou a grade original quando o tempo varia)."""
    b = np.asarray([x for x in beats if 0 <= x < duration], dtype=float)
    raw_db = np.asarray([x for x in downbeats if 0 <= x < duration], dtype=float)
    if len(b) < 16:
        bpm = 60.0 / float(np.median(np.diff(b))) if len(b) >= 2 else 120.0
        return {"beats": [round(float(x), 4) for x in b], "downbeats": [round(float(x), 4) for x in raw_db],
                "bpm": round(bpm, 4), "grid_mode": "raw", "grid_inliers": 0.0, "grid_residual_ms": None,
                "phase_shift_ms": 0.0}

    period, t0, inl, rms = _fit_constant_grid(b)
    inlier_ratio = float(inl.mean())
    bpm = 60.0 / period
    constant = inlier_ratio >= CONST_MIN_INLIERS and rms <= CONST_MAX_RESIDUAL

    if not constant:
        # Tempo variável (ao vivo, rubato): mantém as batidas do allin1; o BPM vem da mediana dos intervalos
        # (a regressão só vale quando a grade é constante)
        return {"beats": [round(float(x), 4) for x in b], "downbeats": [round(float(x), 4) for x in raw_db],
                "bpm": round(60.0 / float(np.median(np.diff(b))), 4), "grid_mode": "variable", "grid_inliers": round(inlier_ratio, 3),
                "grid_residual_ms": round(rms * 1000, 1), "phase_shift_ms": 0.0}

    # Grade cobrindo a faixa inteira: k vai do primeiro t ≥ 0 ao último t < duração
    k_min = int(np.ceil((0.0 - t0) / period))
    k_max = int(np.floor((duration - 0.01 - t0) / period))
    ks = np.arange(k_min, k_max + 1)
    grid = t0 + ks * period

    shift = 0.0
    if y is not None and sr:
        in_music = grid[(grid >= b[0]) & (grid <= b[-1])]
        off = _onset_phase_offset(y, sr, in_music)
        if off is not None:
            shift = off
            grid = grid + shift

    # Tempo 1: combinação de critérios (a grade ainda sem o deslocamento de fase serve de referência)
    phase, phase_detail = _bar_phase_scores(t0, period, ks, raw_db, segments, y, sr)
    keep = grid >= 0
    grid, ks = grid[keep], ks[keep]
    dbs = grid[(ks % 4) == phase]

    return {
        "beats": [round(float(x), 4) for x in grid],
        "downbeats": [round(float(x), 4) for x in dbs],
        "bpm": round(bpm, 4),
        "grid_mode": "constant",
        "grid_inliers": round(inlier_ratio, 3),
        "grid_residual_ms": round(rms * 1000, 1),
        "phase_shift_ms": round(shift * 1000, 1),
        "bar_phase": phase_detail,
    }


def snap_segments(segments: List[dict], downbeats: List[float], beats: List[float], bpm: float) -> List[dict]:
    """Encaixa início/fim de cada seção no downbeat mais próximo (até meio compasso) ou na batida mais próxima."""
    if not segments or not downbeats:
        return segments
    db = np.asarray(downbeats)
    bt = np.asarray(beats) if beats else db
    half_bar = 2.0 * 60.0 / max(bpm, 40.0)

    def snap(t: float) -> float:
        i = int(np.argmin(np.abs(db - t)))
        if abs(db[i] - t) <= half_bar:
            return float(db[i])
        j = int(np.argmin(np.abs(bt - t)))
        return float(bt[j])

    out = []
    for s in segments:
        lbl = str(s.get("label", ""))
        st, en = float(s.get("start", 0.0)), float(s.get("end", 0.0))
        if lbl not in ("start", "end"):
            st = snap(st)
            en = snap(en) if lbl != "end" else en
        out.append({"start": round(st, 4), "end": round(max(en, st), 4), "label": lbl})
    return out


# --------------------------------------------------------------------------- correção manual de andamento

TEMPO_OVERRIDES_FILE = Path(__file__).resolve().parent / "tempo_overrides.json"


def tempo_factor_for(path: str) -> float:
    """Fator de correção de oitava (0.5 ou 2.0) definido em `tempo_overrides.json` para este arquivo, ou 1.0.

    Formato: {"overrides": [{"match": "trecho do caminho", "factor": 2, "note": "por quê"}]}
    O `match` é procurado (sem diferenciar maiúsculas) no caminho completo do arquivo."""
    try:
        data = json.loads(TEMPO_OVERRIDES_FILE.read_text(encoding="utf-8"))
    except Exception:
        return 1.0
    needle_path = unicodedata.normalize("NFC", str(path)).lower()
    for item in data.get("overrides", []):
        match = unicodedata.normalize("NFC", str(item.get("match", ""))).lower()
        factor = float(item.get("factor", 1.0))
        if match and match in needle_path and factor in (0.5, 2.0):
            return factor
    return 1.0


def apply_tempo_factor(grid: Dict, factor: float) -> Dict:
    """Aplica a correção de oitava à grade: `2.0` subdivide cada batida ao meio; `0.5` mantém uma batida em duas.
    Os tempos 1 (downbeats) continuam sobre batidas existentes e o compasso segue com 4 batidas."""
    if factor == 1.0 or len(grid["beats"]) < 8:
        return grid
    beats = list(grid["beats"])
    downbeats = list(grid["downbeats"])
    # Índice da batida original que é o primeiro tempo 1 (âncora da paridade)
    anchor = int(np.argmin(np.abs(np.asarray(beats) - downbeats[0]))) if downbeats else 0

    if factor == 2.0:
        new: List[float] = []
        for i, b in enumerate(beats):
            new.append(b)
            if i + 1 < len(beats):
                new.append((b + beats[i + 1]) / 2.0)
        # um compasso = 4 batidas novas = 2 antigas: tempo 1 a cada 2 batidas originais a partir da âncora
        new_downbeats = [beats[i] for i in range(len(beats)) if (i - anchor) % 2 == 0]
    else:
        new = [beats[i] for i in range(len(beats)) if (i - anchor) % 2 == 0]
        # um compasso = 4 batidas novas = 8 antigas = 2 compassos antigos: um tempo 1 a cada dois
        new_downbeats = [new[i] for i in range(len(new)) if i % 4 == 0]

    out = dict(grid)
    out["beats"] = [round(float(x), 4) for x in new]
    out["downbeats"] = [round(float(x), 4) for x in new_downbeats if x >= 0]
    out["bpm"] = round(float(grid["bpm"]) * factor, 4)
    out["tempo_factor"] = factor
    return out


# --------------------------------------------------------------------------- compassos

def bar_beat_strengths(y: np.ndarray, sr: int, downbeats: List[float], duration: float) -> List[float]:
    """Presença de batida (0..1) por compasso na faixa inteira: energia 35–175 Hz + ataque no grave."""
    import librosa

    dbs = [d for d in downbeats if 0 <= d < duration]
    if not dbs or len(y) == 0:
        return []
    hop = 256
    S = np.abs(librosa.stft(y, n_fft=1024, hop_length=hop)) ** 2
    freqs = librosa.fft_frequencies(sr=sr, n_fft=1024)
    low = S[(freqs >= 35.0) & (freqs <= 175.0), :]
    low_env = np.sqrt(np.mean(low, axis=0))
    ons = librosa.onset.onset_strength(S=librosa.power_to_db(low + 1e-10), sr=sr, hop_length=hop)
    times = librosa.frames_to_time(np.arange(len(low_env)), sr=sr, hop_length=hop)
    p_low = max(float(np.percentile(low_env, 82)), 1e-6)
    p_ons = max(float(np.percentile(ons, 82)), 1e-6)
    out = []
    for i, t_s in enumerate(dbs):
        t_e = dbs[i + 1] if i + 1 < len(dbs) else min(duration, t_s + 2.5)
        a = int(np.searchsorted(times, t_s))
        e = max(a + 1, int(np.searchsorted(times, t_e)))
        if a >= len(low_env):
            out.append(0.0)
            continue
        score = 0.62 * float(np.mean(low_env[a:e])) / p_low + 0.38 * float(np.mean(ons[a:e])) / p_ons
        out.append(round(min(1.0, max(0.0, score)), 3))
    return out


def vocal_envelope(stem_dir: str) -> Optional[Dict]:
    """Envelope de voz a partir dos stems do demucs gravados em disco (vocals/drums/bass/other.wav)."""
    try:
        import soundfile as sf
        from pathlib import Path
        stems = {}
        sr = None
        for name in ("vocals", "drums", "bass", "other"):
            data, sr = sf.read(str(Path(stem_dir) / f"{name}.wav"), always_2d=True)
            stems[name] = data.mean(axis=1)
    except Exception:
        return None
    n = min(len(x) for x in stems.values())
    mix = sum(x[:n] for x in stems.values())
    return vocal_envelope_from_array(stems["vocals"][:n], sr, mix)


def vocal_envelope_from_array(v: np.ndarray, sr: int, mix: np.ndarray) -> Optional[Dict]:
    """Razão voz/mixagem (dB) a cada 50 ms. Medida absoluta: numa faixa instrumental o vazamento do stem de voz
    fica ~25 dB ou mais abaixo da mixagem; voz real fica tipicamente entre -12 e -3 dB."""
    hop = int(sr * 0.05)
    n = min(len(v), len(mix)) // hop
    if n < 10:
        return None
    rv = np.sqrt(np.mean(v[: n * hop].reshape(n, hop) ** 2, axis=1))
    rm = np.sqrt(np.mean(mix[: n * hop].reshape(n, hop) ** 2, axis=1))
    ratio = 20 * np.log10((rv + 1e-9) / (rm + 1e-6))
    ratio[rm < 1e-4] = -60.0  # silêncio na mixagem
    return {"hop": 0.05, "ratio_db": ratio.astype(np.float32)}


# Presença de voz por compasso: -24 dB (vazamento) → 0.0 ... -12 dB ou mais (voz clara) → 1.0
VOCAL_FLOOR_DB = -24.0
VOCAL_FULL_DB = -12.0


def bar_vocal_presence(env: Dict, downbeats: List[float], duration: float) -> List[float]:
    """Presença de voz por compasso (0..1) a partir da razão voz/mixagem."""
    ratio = np.asarray(env["ratio_db"], dtype=float)
    hop = float(env["hop"])
    out = []
    dbs = [d for d in downbeats if 0 <= d < duration]
    for i, t_s in enumerate(dbs):
        t_e = dbs[i + 1] if i + 1 < len(dbs) else min(duration, t_s + 2.5)
        a, e = int(t_s / hop), max(int(t_s / hop) + 1, int(t_e / hop))
        seg = ratio[a:e]
        if len(seg) == 0:
            out.append(0.0)
            continue
        level = float(np.percentile(seg, 75))
        out.append(round(min(1.0, max(0.0, (level - VOCAL_FLOOR_DB) / (VOCAL_FULL_DB - VOCAL_FLOOR_DB))), 3))
    return out


# --------------------------------------------------------------------------- energia

def energy_features(y: np.ndarray, sr: int) -> List[float]:
    """Características de intensidade que não dependem do volume do master (o sinal é normalizado antes)."""
    import librosa

    rms_all = float(np.sqrt(np.mean(y ** 2))) + 1e-9
    yn = y / rms_all * 0.1
    hop = 512
    S = np.abs(librosa.stft(yn, n_fft=2048, hop_length=hop))
    onset = librosa.onset.onset_strength(S=librosa.amplitude_to_db(S), sr=sr, hop_length=hop)
    onset_rate = len(librosa.onset.onset_detect(onset_envelope=onset, sr=sr, hop_length=hop)) / (len(y) / sr)
    centroid = float(np.mean(librosa.feature.spectral_centroid(S=S, sr=sr)))
    flatness = float(np.mean(librosa.feature.spectral_flatness(S=S)))
    frame_rms = librosa.feature.rms(S=S)[0]
    # Compressão/densidade: razão entre o RMS típico e o pico de RMS (faixas "cheias" ficam perto de 1)
    density = float(np.percentile(frame_rms, 50) / (np.percentile(frame_rms, 98) + 1e-9))
    H, P = librosa.decompose.hpss(S, margin=1.0)
    perc_ratio = float(np.mean(P ** 2) / (np.mean(H ** 2) + np.mean(P ** 2) + 1e-12))
    return [onset_rate, centroid, flatness, density, perc_ratio]


ENERGY_WEIGHTS = np.array([0.30, 0.20, 0.10, 0.25, 0.15])


def energy_scores(raw: List[List[float]]) -> Tuple[List[float], Dict]:
    """Converte as características da biblioteca inteira em energia 0..1 (percentil do índice combinado)."""
    mat = np.asarray(raw, dtype=float)
    mean, std = mat.mean(axis=0), mat.std(axis=0) + 1e-9
    idx = ((mat - mean) / std) @ ENERGY_WEIGHTS
    order = np.sort(idx)
    pct = np.searchsorted(order, idx, side="right") / len(order)
    stats = {"mean": mean.tolist(), "std": std.tolist(), "weights": ENERGY_WEIGHTS.tolist(),
             "reference": [float(x) for x in order]}
    return [round(float(p), 4) for p in pct], stats


def energy_from_stats(raw: List[float], stats: Dict) -> float:
    """Energia de uma faixa nova usando a distribuição já gravada da biblioteca."""
    idx = float(((np.asarray(raw) - np.asarray(stats["mean"])) / np.asarray(stats["std"])) @ np.asarray(stats["weights"]))
    ref = np.asarray(stats["reference"])
    return round(float(np.searchsorted(ref, idx, side="right") / len(ref)), 4)


# --------------------------------------------------------------------------- tom

def camelot_from_text(raw: str) -> Optional[Tuple[str, str]]:
    """Converte uma tag de tom ('Am', 'F#m', '8A', 'Ebmaj', 'D minor') em (camelot, nome)."""
    s = str(raw or "").strip().upper().replace("♯", "#").replace("♭", "B").replace("MINOR", "M").replace("MAJOR", "")
    s = s.replace("MIN", "M").replace("MAJ", "").replace(" ", "")
    m = re.fullmatch(r"(\d{1,2})([AB])", s)
    if m and 1 <= int(m.group(1)) <= 12:
        cam = f"{int(m.group(1))}{m.group(2)}"
        table = CAMELOT_MINOR if m.group(2) == "A" else CAMELOT_MAJOR
        root = table.index(cam)
        return cam, KEY_NAMES[root] + ("m" if m.group(2) == "A" else "")
    m = re.fullmatch(r"([A-G][#B]?)(M)?", s)
    if not m or m.group(1) not in NOTE_INDEX:
        return None
    root = NOTE_INDEX[m.group(1)]
    minor = m.group(2) == "M"
    return (CAMELOT_MINOR if minor else CAMELOT_MAJOR)[root], KEY_NAMES[root] + ("m" if minor else "")


def key_from_tags(path: str) -> Optional[Tuple[str, str]]:
    try:
        out = subprocess.run([FFPROBE, "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path],
                             capture_output=True, text=True, timeout=30).stdout
        data = json.loads(out or "{}")
    except Exception:
        return None
    tags: Dict[str, str] = {}
    for block in [data.get("format", {})] + list(data.get("streams", [])):
        for k, v in (block.get("tags") or {}).items():
            tags.setdefault(k.lower(), v)
    raw = tags.get("initialkey") or tags.get("tkey") or tags.get("key")
    return camelot_from_text(raw) if raw else None


_KEY_PROC = None


def key_from_madmom(path: str) -> Optional[Tuple[str, str]]:
    global _KEY_PROC
    try:
        from madmom.features.key import CNNKeyRecognitionProcessor, key_prediction_to_label
        if _KEY_PROC is None:
            _KEY_PROC = CNNKeyRecognitionProcessor()
        note, mode = key_prediction_to_label(_KEY_PROC(path)).split()
        root = NOTE_INDEX[note.upper()]
        minor = mode == "minor"
        return (CAMELOT_MINOR if minor else CAMELOT_MAJOR)[root], KEY_NAMES[root] + ("m" if minor else "")
    except Exception:
        return None


def detect_key(path: str) -> Tuple[Optional[str], Optional[str], str]:
    """(camelot, nome, origem): tag do arquivo quando existe, senão madmom CNN."""
    tagged = key_from_tags(path)
    if tagged:
        return tagged[0], tagged[1], "tag"
    cnn = key_from_madmom(path)
    if cnn:
        return cnn[0], cnn[1], "madmom"
    return None, None, "none"
