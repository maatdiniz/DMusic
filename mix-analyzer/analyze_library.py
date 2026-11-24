#!/usr/bin/env python3
"""
Analisa a biblioteca local de músicas usando pipeline Produtor-Consumidor no Mac M4:
  - Produtor único (GPU MPS): mantém `demucs.api.Separator` carregado na GPU Metal,
    separando stems continuamente sem disputa entre múltiplos processos Metal.
  - Consumidores leves (CPU paralela): carregam apenas `harmonix-fold0` (1,4 MB) + `librosa`,
    extraindo espectrogramas, beats, downbeats, estrutura, Camelot e energia RMS em paralelo.

Grava cada faixa em `<music-dir>/_diniz_mix/tracks/<sha1>.json` (com `.ndignore` para o Navidrome)
e envia em tempo real via POST `/api/ingest` ao servidor DMusic Mix (:4534).

Pós-processamento (postprocess.py): grade de tempo constante, BPM exato, tempo 1 por múltiplos critérios,
seções no downbeat, bar_beat da faixa inteira, energia por percentil da biblioteca, tom (tag > madmom CNN)
e presença de voz por compasso (stem de voz do demucs).

Modos:
  (padrão)            analisa faixas novas/alteradas (demucs + allin1 + pós-processamento)
  --reprocess         refaz só o pós-processamento de todos os JSONs (sem demucs/allin1), usando `allin1_raw`
  --vocals-backfill   roda o demucs nas faixas sem `vocal_env` para gerar a presença de voz por compasso
  --sync-only         reenvia os JSONs existentes ao servidor
"""

import argparse
from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, as_completed, wait
import gc
import hashlib
import json
import multiprocessing
import os
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
from pathlib import Path
import shutil
import sys
import time
from typing import Dict, List, Optional, Tuple
import unicodedata

# postprocess.py fica ao lado deste script (também nos workers "spawn")
sys.path.insert(0, str(Path(__file__).resolve().parent))

AUDIO_EXTS = {
    ".flac", ".mp3", ".m4a", ".aiff", ".aif", ".wav", ".ogg", ".opus", ".aac", ".alac", ".wv"
}

MAJOR_PROFILE = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
MINOR_PROFILE = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

CAMELOT_MAJOR = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
CAMELOT_MINOR = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]
KEY_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Modelo leve carregado uma única vez por processo consumidor CPU (sem Demucs/MPS)
_MODEL = None


def norm_rel(p: str) -> str:
    return unicodedata.normalize("NFC", p.replace("\\", "/").strip("/"))


def track_hash(rel_nfc: str) -> str:
    return hashlib.sha1(rel_nfc.encode("utf-8")).hexdigest()


def ensure_output_dirs(music_dir: Path) -> Tuple[Path, Path]:
    # O servidor (mix_engine.SYNC_DIR) lê `_diniz_mix`; `_dmusic_mix` só é usado se já existir sozinho.
    sync_dir = music_dir / "_diniz_mix"
    if not sync_dir.exists() and (music_dir / "_dmusic_mix").exists():
        sync_dir = music_dir / "_dmusic_mix"
    tracks_dir = sync_dir / "tracks"
    tracks_dir.mkdir(parents=True, exist_ok=True)
    ndignore = sync_dir / ".ndignore"
    if not ndignore.exists():
        ndignore.write_text("", encoding="utf-8")
    return sync_dir, tracks_dir


def estimate_camelot_and_key(chroma_mean) -> Tuple[str, str]:
    import numpy as np

    vec = np.asarray(chroma_mean, dtype=float)
    if vec.size != 12 or float(np.std(vec)) < 1e-8:
        return "8A", "Am"

    maj_p = np.asarray(MAJOR_PROFILE, dtype=float)
    min_p = np.asarray(MINOR_PROFILE, dtype=float)
    best_corr = -2.0
    best_cam = "8A"
    best_key = "Am"

    for root in range(12):
        shifted = np.roll(vec, -root)
        maj_c = float(np.corrcoef(shifted, maj_p)[0, 1])
        if maj_c > best_corr:
            best_corr = maj_c
            best_cam = CAMELOT_MAJOR[root]
            best_key = KEY_NAMES[root]

        min_c = float(np.corrcoef(shifted, min_p)[0, 1])
        if min_c > best_corr:
            best_corr = min_c
            best_cam = CAMELOT_MINOR[root]
            best_key = f"{KEY_NAMES[root]}m"

    return best_cam, best_key


def _nearest_downbeat(target: float, downbeats: List[float], lo: float, hi: float) -> float:
    if hi < lo:
        hi = lo
    cands = [d for d in downbeats if lo <= d <= hi]
    if cands:
        return round(min(cands, key=lambda d: abs(d - target)), 3)
    return round(min(max(target, lo), hi), 3)


def compute_phrase_points(
    duration: float,
    bpm: float,
    beats: List[float],
    downbeats: List[float],
    segments: List[dict],
) -> Tuple[float, float]:
    bar_sec = 4.0 * 60.0 / max(bpm, 60.0)
    guard_tail = max(4.0 * bar_sec, 6.0)
    min_out = duration * 0.50
    max_out = max(min_out, duration - 0.5 - guard_tail)

    chosen_out: Optional[float] = None
    outro_segs = [
        s for s in segments
        if str(s.get("label", "")).lower() == "outro" and float(s.get("start", 0)) >= min_out
    ]
    if outro_segs:
        for s in outro_segs:
            st = float(s["start"])
            if st <= max_out + bar_sec:
                chosen_out = _nearest_downbeat(st, downbeats, min_out, max_out)
                break

    if chosen_out is None:
        late_bounds: List[float] = []
        for s in segments:
            lbl = str(s.get("label", "")).lower()
            st = float(s.get("start", 0))
            en = float(s.get("end", 0))
            if lbl == "chorus" and en >= duration * 0.52 and en <= max_out + bar_sec:
                late_bounds.append(en)
            elif lbl in ("bridge", "break", "inst", "solo", "instrumental") and st >= duration * 0.55 and st <= max_out + bar_sec:
                late_bounds.append(st)
        if late_bounds:
            chosen_out = _nearest_downbeat(late_bounds[-1], downbeats, min_out, max_out)

    if chosen_out is None:
        fallback_out = max(duration * 0.65, duration - 12.0 * bar_sec)
        chosen_out = _nearest_downbeat(fallback_out, downbeats, min(duration * 0.52, max_out), max_out)

    max_in = duration * 0.40
    chosen_in: Optional[float] = None
    for s in segments:
        lbl = str(s.get("label", "")).lower()
        st = float(s.get("start", 0))
        if lbl in ("intro", "verse", "chorus") and 0.0 <= st < max_in:
            in_cands = [d for d in downbeats if max(0.0, st - 0.5) <= d < max_in]
            if in_cands:
                chosen_in = round(in_cands[0], 3)
            else:
                chosen_in = round(st, 3)
            break

    if chosen_in is None:
        early_dbs = [d for d in downbeats if 0.25 <= d < max_in]
        if early_dbs:
            chosen_in = round(early_dbs[0], 3)
        else:
            chosen_in = 0.0

    return chosen_in, chosen_out


def extract_raw_vibe_features(file_path: str, duration: Optional[float] = None) -> List[float]:
    """
    Extrai assinatura acústica/timbral/rítmica de 24 dimensões do miolo da faixa (~45s):
      - 12 MFCCs (1..12): timbre, instrumentação, vocais, textura de synths/piano vs graves distorcidos
      - 4 bandas espectrais: Sub (20-85Hz), Bass (85-250Hz), Mid (250-2kHz), High (2-10kHz)
      - 8 descritores de emoção/grooves: razão harmônico/percussivo (HPSS), brilho (centroid),
        aspereza (flatness), contraste espectral (low/mid/high), punch rítmico (onset CV) e
        constância four-on-the-floor (autocorrelação de onsets).
    """
    import librosa
    import numpy as np

    dur = float(duration) if duration and duration > 0 else get_audio_duration(file_path)
    offset = min(max(15.0, dur * 0.25), max(0.0, dur - 45.0)) if dur > 50.0 else 0.0
    y, sr = librosa.load(file_path, sr=22050, mono=True, offset=offset, duration=45.0)
    if len(y) < sr * 3:
        y, sr = librosa.load(file_path, sr=22050, mono=True, duration=45.0)
    if len(y) == 0:
        return [0.0] * 24

    rms_val = float(np.sqrt(np.mean(y ** 2)) + 1e-8)
    y_norm = y / rms_val * 0.1

    S = np.abs(librosa.stft(y_norm, n_fft=2048, hop_length=1024))
    S_pow = S ** 2
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)

    mel = librosa.feature.melspectrogram(S=S_pow, sr=sr)
    mel_db = librosa.power_to_db(mel + 1e-10)
    mfcc = librosa.feature.mfcc(S=mel_db, n_mfcc=13)
    mfcc_mean = np.mean(mfcc[1:13], axis=1)  # 12 dims

    total_e = float(np.sum(S_pow)) + 1e-10
    sub = float(np.sum(S_pow[(freqs >= 20) & (freqs < 85)])) / total_e
    bass = float(np.sum(S_pow[(freqs >= 85) & (freqs < 250)])) / total_e
    mid = float(np.sum(S_pow[(freqs >= 250) & (freqs < 2000)])) / total_e
    high = float(np.sum(S_pow[(freqs >= 2000) & (freqs < 10000)])) / total_e

    H, P = librosa.decompose.hpss(S, margin=1.5)
    harm_e = float(np.mean(H ** 2))
    perc_e = float(np.mean(P ** 2))
    hp_ratio = harm_e / (harm_e + perc_e + 1e-10)

    centroid = float(np.mean(librosa.feature.spectral_centroid(S=S, sr=sr))) / 4000.0
    flatness = float(np.mean(librosa.feature.spectral_flatness(S=S))) * 15.0
    contrast = np.mean(librosa.feature.spectral_contrast(S=S, sr=sr), axis=1)
    c_low = float(contrast[0])
    c_mid = float(np.mean(contrast[2:5]))
    c_high = float(contrast[-1])

    onset_env = librosa.onset.onset_strength(S=mel_db, sr=sr, hop_length=1024)
    pulse_cv = float(np.std(onset_env)) / (float(np.mean(onset_env)) + 1e-6)
    ac = librosa.autocorrelate(onset_env, max_size=40)
    ac_norm = ac / (ac[0] + 1e-8)
    steadiness = float(np.max(ac_norm[4:28])) if len(ac_norm) > 28 else 0.5

    raw = np.concatenate([
        mfcc_mean,
        [sub, bass, mid, high, hp_ratio, centroid, flatness, c_low, c_mid, c_high, pulse_cv, steadiness],
    ])
    raw = np.nan_to_num(raw, nan=0.0, posinf=0.0, neginf=0.0)
    return [round(float(x), 5) for x in raw]


def standardize_vibe(raw_vec: List[float], stats: Optional[dict] = None) -> List[float]:
    """Padroniza (Z-score relativo à biblioteca) e normaliza em L2 para cosseno calibrado."""
    import numpy as np

    arr = np.asarray(raw_vec, dtype=np.float64)
    if arr.size != 24:
        return []
    # Pesos por grupo: timbre MFCC (1.0), bandas de frequência (1.45), harmônico/brilho/groove (1.35)
    weights = np.array([1.0] * 12 + [1.45] * 4 + [1.35] * 8, dtype=np.float64)

    if stats and len(stats.get("mean", [])) == 24 and len(stats.get("std", [])) == 24:
        mean = np.asarray(stats["mean"], dtype=np.float64)
        std = np.maximum(np.asarray(stats["std"], dtype=np.float64), 1e-4)
        z = np.clip((arr - mean) / std, -4.0, 4.0) * weights
    else:
        # Fallback razoável caso ainda não exista vibe_stats.json
        default_mean = np.array(
            [65.0, -5.0, 20.0, 0.0, 8.0, 0.0, 4.0, 0.0, 2.0, 0.0, 1.0, 0.0,
             0.45, 0.28, 0.18, 0.08, 0.65, 0.55, 0.50, 20.0, 18.0, 22.0, 0.90, 0.55],
            dtype=np.float64,
        )
        default_std = np.array(
            [28.0] * 12 + [0.18, 0.12, 0.12, 0.07, 0.16, 0.18, 0.50, 5.0, 4.0, 5.0, 0.35, 0.18],
            dtype=np.float64,
        )
        z = np.clip((arr - default_mean) / default_std, -4.0, 4.0) * weights

    norm = float(np.linalg.norm(z))
    if norm < 1e-8:
        return [0.0] * 24
    unit = z / norm
    return [round(float(x), 4) for x in unit]


def _extract_vibe_job(job: Tuple[str, str, float]) -> Tuple[str, Optional[List[float]], str]:
    json_path_str, audio_path_str, dur = job
    try:
        raw = extract_raw_vibe_features(audio_path_str, duration=dur)
        return json_path_str, raw, ""
    except Exception as exc:
        return json_path_str, None, f"{type(exc).__name__}: {exc}"


def backfill_vibe_library(
    music_dir: Path,
    tracks_dir: Path,
    server_url: str,
    workers: int = 8,
    itunes_tracks_dir: Optional[Path] = None,
    itunes_music_dir: Optional[Path] = None,
) -> None:
    """
    Calcula o vetor `vibe` (24D Z-score L2) para todas as faixas já analisadas
    (Soulseek + iTunes), grava `vibe_stats.json`, atualiza os JSONs e envia ao servidor.
    """
    import numpy as np
    import requests

    targets: List[Tuple[Path, Path, dict]] = []
    # 1. Soulseek tracks
    for jp in sorted(tracks_dir.glob("*.json")):
        try:
            d = json.loads(jp.read_text(encoding="utf-8"))
            rel = d.get("rel_path", "")
            ap = music_dir / rel
            if ap.is_file():
                targets.append((jp, ap, d))
        except Exception:
            continue

    # 2. iTunes tracks (opcional)
    if itunes_tracks_dir and itunes_tracks_dir.is_dir() and itunes_music_dir and itunes_music_dir.is_dir():
        for jp in sorted(itunes_tracks_dir.glob("*.json")):
            try:
                d = json.loads(jp.read_text(encoding="utf-8"))
                rel = d.get("rel_path", "")
                sub = rel[len("iTunes/"):] if rel.startswith("iTunes/") else rel
                ap = itunes_music_dir / sub
                if ap.is_file():
                    targets.append((jp, ap, d))
            except Exception:
                continue

    print(f"Backfill de Vibe/Timbre: {len(targets)} faixas encontradas ({workers} workers CPU)...", flush=True)
    if not targets:
        return

    t0 = time.time()
    jobs = [(str(jp), str(ap), float(d.get("duration") or 0.0)) for jp, ap, d in targets]
    raw_by_json: Dict[str, List[float]] = {}
    errors = 0

    ctx = multiprocessing.get_context("spawn")
    with ProcessPoolExecutor(max_workers=max(1, workers), mp_context=ctx) as ex:
        futs = [ex.submit(_extract_vibe_job, j) for j in jobs]
        done = 0
        for fut in as_completed(futs):
            jp_str, raw, err = fut.result()
            done += 1
            if raw is not None and len(raw) == 24:
                raw_by_json[jp_str] = raw
            else:
                errors += 1
            if done % 50 == 0 or done == len(jobs):
                elapsed = time.time() - t0
                rate = done / max(elapsed, 0.1)
                print(f"  [{done}/{len(jobs)}] extraídos ({len(raw_by_json)} ok, {errors} err) | {rate:.1f} faixas/s", flush=True)

    if not raw_by_json:
        print("Nenhum vetor de vibe extraído.", flush=True)
        return

    mat = np.asarray(list(raw_by_json.values()), dtype=np.float64)
    stats = {
        "dim": 24,
        "count": int(mat.shape[0]),
        "mean": [round(float(x), 6) for x in np.mean(mat, axis=0)],
        "std": [round(float(x), 6) for x in np.std(mat, axis=0)],
        "updated_at": time.time(),
    }
    stats_path = tracks_dir.parent / "vibe_stats.json"
    stats_path.write_text(json.dumps(stats, indent=2), encoding="utf-8")
    print(f"Estatísticas Z-score salvas em {stats_path} (N={stats['count']}). Atualizando JSONs e servidor...", flush=True)

    synced = 0
    for idx, (jp, _, d) in enumerate(targets, 1):
        raw = raw_by_json.get(str(jp))
        if raw is None:
            continue
        d["vibe"] = standardize_vibe(raw, stats)
        tmp = f"{jp}.tmp.{os.getpid()}"
        Path(tmp).write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, jp)
        if server_url:
            try:
                r = requests.post(f"{server_url.rstrip('/')}/api/ingest", json=d, timeout=5)
                if r.status_code in (200, 202):
                    synced += 1
            except Exception:
                pass
        if idx % 100 == 0 or idx == len(targets):
            print(f"  [{idx}/{len(targets)}] sincronizados com servidor ({synced} OK)", flush=True)

    print(f"Backfill de Vibe concluído em {time.time() - t0:.1f}s ({len(raw_by_json)} faixas, {synced} enviadas ao servidor).", flush=True)


def get_audio_duration(file_path: str) -> float:
    import librosa
    import soundfile as sf

    try:
        return float(sf.info(file_path).duration)
    except Exception:
        return float(librosa.get_duration(path=file_path))


def _compact_vocal_env(env: Optional[dict]) -> Optional[dict]:
    """Guarda a razão voz/mixagem em dB inteiros (50 ms) no JSON, para o --reprocess recalcular
    a presença de voz por compasso sem rodar o demucs de novo."""
    import numpy as np

    if not env:
        return None
    db = np.clip(np.round(np.asarray(env["ratio_db"], dtype=float)), -60, 12).astype(int)
    return {"hop": env["hop"], "ratio_db": db.tolist()}


def _expand_vocal_env(compact: Optional[dict]) -> Optional[dict]:
    if not compact or not compact.get("ratio_db"):
        return None  # formato antigo (relativo ao pico da própria voz) é descartado
    return {"hop": float(compact["hop"]), "ratio_db": compact["ratio_db"]}


def finalize_analysis(
    file_path: str,
    raw: dict,
    duration: float,
    y,
    sr: int,
    vocal_env: Optional[dict] = None,
    energy_stats: Optional[dict] = None,
) -> dict:
    """Pós-processamento comum (análise completa e --reprocess) a partir do resultado bruto do allin1.
    `raw` = {"bpm", "beats", "downbeats", "segments"} exatamente como o allin1 devolveu."""
    import librosa
    import numpy as np
    import postprocess as pp

    grid = pp.regularize_grid(raw.get("beats") or [], raw.get("downbeats") or [], duration, y, sr, raw.get("segments") or [])
    tempo_factor = pp.tempo_factor_for(file_path)  # correção manual de oitava (tempo_overrides.json)
    if tempo_factor != 1.0:
        grid = pp.apply_tempo_factor(grid, tempo_factor)
    beats, downbeats = grid["beats"], grid["downbeats"]
    bpm = float(grid["bpm"] or raw.get("bpm") or 120.0)
    if not downbeats and beats:
        downbeats = beats[::4]
    segments = pp.snap_segments(raw.get("segments") or [], downbeats, beats, bpm)

    camelot, musical_key, key_source = pp.detect_key(file_path)
    if not camelot:
        chroma = librosa.feature.chroma_cqt(y=librosa.effects.harmonic(y, margin=3.0), sr=sr)
        camelot, musical_key = estimate_camelot_and_key(np.mean(chroma, axis=1))
        key_source = "chroma"

    energy_raw = pp.energy_features(y, sr)
    energy = pp.energy_from_stats(energy_raw, energy_stats) if energy_stats else None

    mix_in_sec, mix_out_sec = compute_phrase_points(duration, bpm, beats, downbeats, segments)
    out = {
        "bpm": round(bpm, 4),
        "beats": beats,
        "downbeats": downbeats,
        "segments": segments,
        "grid_mode": grid["grid_mode"],
        "grid_inliers": grid.get("grid_inliers"),
        "grid_residual_ms": grid.get("grid_residual_ms"),
        "phase_shift_ms": grid.get("phase_shift_ms"),
        "bar_phase": grid.get("bar_phase"),
        "bar_beat": pp.bar_beat_strengths(y, sr, downbeats, duration),
        "camelot": camelot,
        "musical_key": musical_key,
        "key_source": key_source,
        "tempo_factor": tempo_factor,
        "energy_raw": [round(float(x), 6) for x in energy_raw],
        "mix_in_sec": mix_in_sec,
        "mix_out_sec": mix_out_sec,
        "analysis_version": pp.ANALYSIS_VERSION,
    }
    if energy is not None:
        out["energy"] = energy
    if vocal_env:
        out["bar_vocal"] = pp.bar_vocal_presence(vocal_env, downbeats, duration)
    return out


def _init_cpu_worker(model_name: str, cpu_threads: int) -> None:
    global _MODEL
    os.environ["OMP_NUM_THREADS"] = str(cpu_threads)
    os.environ["MKL_NUM_THREADS"] = str(cpu_threads)

    import torch
    from allin1.models import load_pretrained_model

    torch.set_num_threads(cpu_threads)
    _MODEL = load_pretrained_model(model_name=model_name, device="cpu")


def analyze_cpu_task(job: Tuple[str, str, str, str, str, str, float, str]) -> dict:
    file_path, rel_nfc, json_path_str, server_url, work_root_str, demix_out_str, demix_elapsed, demix_err = job
    t0 = time.time()

    import librosa
    import numpy as np
    import requests
    import torch
    from allin1.helpers import run_inference
    from allin1.spectrogram import extract_spectrograms

    audio_path = Path(file_path)
    t_hash = Path(json_path_str).stem
    work_root = Path(work_root_str)
    spec_dir = work_root / "spec"
    spec_dir.mkdir(parents=True, exist_ok=True)

    bpm = 120.0
    beats: List[float] = []
    downbeats: List[float] = []
    segments: List[dict] = []
    analyzer_name = "allin1"

    try:
        if demix_out_str and Path(demix_out_str).is_dir():
            spec_paths = extract_spectrograms([Path(demix_out_str)], spec_dir, multiprocess=False)
            with torch.no_grad():
                res = run_inference(
                    path=audio_path,
                    spec_path=spec_paths[0],
                    model=_MODEL,
                    device="cpu",
                    include_activations=False,
                    include_embeddings=False,
                )
            bpm = float(getattr(res, "bpm", 0.0) or 0.0)
            beats = [round(float(x), 4) for x in (getattr(res, "beats", None) or [])]
            downbeats = [round(float(x), 4) for x in (getattr(res, "downbeats", None) or [])]
            raw_segs = getattr(res, "segments", None) or []
            segments = [
                {
                    "start": round(float(s.start), 3),
                    "end": round(float(s.end), 3),
                    "label": str(s.label),
                }
                for s in raw_segs
            ]
        else:
            analyzer_name = f"librosa-fallback ({demix_err or 'demix-failed'})"
    except Exception as exc:
        analyzer_name = f"librosa-fallback ({type(exc).__name__})"
    finally:
        # Lê o envelope do stem de voz antes de apagar os stems (presença de voz por compasso)
        vocal_env = None
        if demix_out_str and Path(demix_out_str, "vocals.wav").is_file():
            import postprocess as pp
            vocal_env = pp.vocal_envelope(demix_out_str)
        shutil.rmtree(work_root, ignore_errors=True)

    duration = get_audio_duration(file_path)
    # Faixa inteira (antes eram só 240 s e os compassos depois de 4:00 ficavam com bar_beat = 0)
    y, sr = librosa.load(file_path, sr=22050, mono=True)

    if not beats or bpm <= 0:
        tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
        bpm_est = float(np.atleast_1d(tempo)[0])
        if bpm <= 0 and bpm_est > 0:
            bpm = bpm_est
        if not beats:
            beats = [round(float(t), 4) for t in librosa.frames_to_time(beat_frames, sr=sr)]
    if not downbeats and beats:
        downbeats = beats[::4]

    raw = {"bpm": bpm, "beats": beats, "downbeats": downbeats, "segments": segments}
    stats_dir = Path(json_path_str).parent.parent
    energy_stats_path = stats_dir / "energy_stats.json"
    energy_stats = json.loads(energy_stats_path.read_text(encoding="utf-8")) if energy_stats_path.is_file() else None
    final = finalize_analysis(file_path, raw, duration, y, sr, vocal_env=vocal_env, energy_stats=energy_stats)
    if "energy" not in final:
        final["energy"] = 0.5

    vibe_vec: List[float] = []
    try:
        raw_vibe = extract_raw_vibe_features(file_path, duration=duration)
        stats_path = Path(json_path_str).parent.parent / "vibe_stats.json"
        vibe_stats = json.loads(stats_path.read_text(encoding="utf-8")) if stats_path.is_file() else None
        vibe_vec = standardize_vibe(raw_vibe, vibe_stats)
    except Exception:
        vibe_vec = []

    st = os.stat(file_path)

    payload = {
        "rel_path": rel_nfc,
        "hash": t_hash,
        "size": st.st_size,
        "mtime": st.st_mtime,
        "duration": round(duration, 3),
        **final,
        "vibe": vibe_vec,
        "vocal_env": _compact_vocal_env(vocal_env),
        "allin1_raw": raw,
        "analyzer": analyzer_name,
        "analyzed_at": time.time(),
    }

    tmp_json = f"{json_path_str}.tmp.{os.getpid()}"
    with open(tmp_json, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp_json, json_path_str)

    ingested = "local"
    if server_url:
        try:
            r = requests.post(f"{server_url.rstrip('/')}/api/ingest", json=payload, timeout=5)
            ingested = f"srv:{r.status_code}"
        except Exception:
            ingested = "srv:offline"

    return {
        "rel_path": rel_nfc,
        "bpm": payload["bpm"],
        "camelot": payload["camelot"],
        "energy": payload["energy"],
        "mix_in": payload["mix_in_sec"],
        "mix_out": payload["mix_out_sec"],
        "analyzer": analyzer_name,
        "elapsed_demix": round(demix_elapsed, 2),
        "elapsed_cpu": round(time.time() - t0, 2),
        "ingested": ingested,
    }


def _library_targets(
    tracks_dir: Path,
    music_dir: Path,
    itunes_tracks_dir: Optional[Path],
    itunes_music_dir: Optional[Path],
) -> List[Tuple[Path, Path]]:
    """(json, áudio) de todas as faixas analisadas: Soulseek (`music_dir`) + iTunes (`rel_path` = "iTunes/...")."""
    out: List[Tuple[Path, Path]] = []
    for jp in sorted(tracks_dir.glob("*.json")):
        try:
            rel = json.loads(jp.read_text(encoding="utf-8")).get("rel_path", "")
        except Exception:
            continue
        ap = music_dir / rel
        if ap.is_file():
            out.append((jp, ap))
    if itunes_tracks_dir and itunes_tracks_dir.is_dir() and itunes_music_dir and itunes_music_dir.is_dir():
        for jp in sorted(itunes_tracks_dir.glob("*.json")):
            try:
                rel = json.loads(jp.read_text(encoding="utf-8")).get("rel_path", "")
            except Exception:
                continue
            ap = itunes_music_dir / (rel[len("iTunes/"):] if rel.startswith("iTunes/") else rel)
            if ap.is_file():
                out.append((jp, ap))
    return out


def _reprocess_job(job: Tuple[str, str]) -> Tuple[str, Optional[dict], str]:
    json_path, audio_path = job
    try:
        import librosa

        d = json.loads(Path(json_path).read_text(encoding="utf-8"))
        # Sempre parte do resultado bruto do allin1 (idempotente: rodar de novo não acumula ajustes)
        raw = d.get("allin1_raw") or {
            "bpm": d.get("bpm"), "beats": d.get("beats") or [], "downbeats": d.get("downbeats") or [],
            "segments": d.get("segments") or [],
        }
        duration = float(d.get("duration") or get_audio_duration(audio_path))
        y, sr = librosa.load(audio_path, sr=22050, mono=True)
        final = finalize_analysis(audio_path, raw, duration, y, sr, vocal_env=_expand_vocal_env(d.get("vocal_env")))
        d.update(final)
        d["allin1_raw"] = raw
        return json_path, d, ""
    except Exception as exc:
        return json_path, None, f"{type(exc).__name__}: {exc}"


def _post_ingest(server_url: str, payload: dict) -> bool:
    import requests

    try:
        r = requests.post(f"{server_url.rstrip('/')}/api/ingest", json=payload, timeout=20)
        return r.status_code in (200, 202)
    except Exception:
        return False


def reprocess_library(
    targets: List[Tuple[Path, Path]],
    stats_dir: Path,
    server_url: str,
    workers: int,
    out_dir: Optional[Path] = None,
    partial: bool = False,
) -> None:
    """Refaz o pós-processamento de toda a biblioteca sem demucs/allin1. Com `out_dir`, grava as versões novas
    lá (ensaio) sem tocar nos JSONs originais nem no servidor."""
    import postprocess as pp

    print(f"Reprocessando {len(targets)} faixas ({workers} workers)...", flush=True)
    t0 = time.time()
    results: Dict[str, dict] = {}
    errors = 0
    ctx = multiprocessing.get_context("spawn")
    with ProcessPoolExecutor(max_workers=max(1, workers), mp_context=ctx) as ex:
        futs = [ex.submit(_reprocess_job, (str(jp), str(ap))) for jp, ap in targets]
        for n, fut in enumerate(as_completed(futs), 1):
            jp, d, err = fut.result()
            if d is None:
                errors += 1
                print(f"  ERRO {Path(jp).name}: {err}", flush=True)
            else:
                results[jp] = d
            if n % 50 == 0 or n == len(futs):
                print(f"  [{n}/{len(futs)}] {len(results)} ok, {errors} erros | {n / max(time.time() - t0, 0.1):.2f} faixas/s", flush=True)

    # Energia: percentil do índice combinado na biblioteca inteira.
    # Num reprocessamento parcial (--only) usa as estatísticas já gravadas, sem recalculá-las nem sobrescrevê-las.
    keys = list(results.keys())
    existing_stats_path = stats_dir / "energy_stats.json"
    if partial and existing_stats_path.is_file():
        stats = json.loads(existing_stats_path.read_text(encoding="utf-8"))
        for k in keys:
            results[k]["energy"] = pp.energy_from_stats(results[k]["energy_raw"], stats)
    else:
        scores, stats = pp.energy_scores([results[k]["energy_raw"] for k in keys])
        for k, e in zip(keys, scores):
            results[k]["energy"] = e
        stats_target = (out_dir or stats_dir) / "energy_stats.json"
        stats_target.parent.mkdir(parents=True, exist_ok=True)
        stats_target.write_text(json.dumps({**stats, "count": len(keys), "updated_at": time.time()}), encoding="utf-8")

    synced = 0
    for i, (jp, d) in enumerate(results.items(), 1):
        dst = (out_dir / Path(jp).name) if out_dir else Path(jp)
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = f"{dst}.tmp.{os.getpid()}"
        Path(tmp).write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, dst)
        if out_dir is None and server_url and _post_ingest(server_url, d):
            synced += 1
        if i % 100 == 0 or i == len(results):
            print(f"  [{i}/{len(results)}] gravados" + ("" if out_dir else f" | {synced} enviados ao servidor"), flush=True)
    print(f"Reprocessamento concluído em {time.time() - t0:.0f}s ({len(results)} ok, {errors} erros)", flush=True)


def vocals_backfill(
    targets: List[Tuple[Path, Path]],
    server_url: str,
    demix_device: str,
    limit: int = 0,
    reverse: bool = False,
    torch_threads: int = 0,
) -> None:
    """Roda o demucs nas faixas sem `vocal_env` e grava a presença de voz por compasso (`bar_vocal`).

    Pode rodar em dois processos ao mesmo tempo (ex.: um na GPU/MPS e outro na CPU com `--reverse`):
    cada JSON é relido logo antes de processar, então um processo pula o que o outro já fez."""
    import demucs.api
    import postprocess as pp
    import torch

    if torch_threads > 0:
        torch.set_num_threads(torch_threads)
    order = list(reversed(targets)) if reverse else list(targets)
    todo = []
    for jp, ap in order:
        try:
            if not (json.loads(jp.read_text(encoding="utf-8")).get("vocal_env") or {}).get("ratio_db"):
                todo.append((jp, ap))
        except Exception:
            continue
    if limit > 0:
        todo = todo[:limit]
    device = demix_device if demix_device != "auto" else ("mps" if torch.backends.mps.is_available() else "cpu")
    tag = f"{device}{' (reverso)' if reverse else ''}"
    print(f"Backfill de voz [{tag}]: {len(todo)} faixas sem envelope de voz", flush=True)
    if not todo:
        return
    sep = demucs.api.Separator(model="htdemucs", device=device, progress=False)
    t0 = time.time()
    done = 0
    for n, (jp, ap) in enumerate(todo, 1):
        try:
            d = json.loads(jp.read_text(encoding="utf-8"))
            if (d.get("vocal_env") or {}).get("ratio_db"):
                continue  # o outro processo já fez esta faixa
            _, separated = sep.separate_audio_file(ap)
            stems = {k: t.detach().cpu().numpy().mean(axis=0) for k, t in separated.items()}
            del separated
            env = pp.vocal_envelope_from_array(stems["vocals"], sep.samplerate, sum(stems.values()))
            d = json.loads(jp.read_text(encoding="utf-8"))
            if (d.get("vocal_env") or {}).get("ratio_db"):
                continue
            d["vocal_env"] = _compact_vocal_env(env)
            if env:
                d["bar_vocal"] = pp.bar_vocal_presence(env, d.get("downbeats") or [], float(d.get("duration") or 0))
            tmp = f"{jp}.tmp.{os.getpid()}"
            Path(tmp).write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, jp)
            ok = _post_ingest(server_url, d) if server_url else False
            done += 1
            rate = done / max(time.time() - t0, 0.1)
            print(f"[{tag} {n}/{len(todo)}] voz ok | srv:{'ok' if ok else 'falhou'} | {rate * 60:.1f} faixas/min | {d.get('rel_path')}", flush=True)
        except Exception as exc:
            print(f"[{tag} {n}/{len(todo)}] ERRO {ap.name}: {type(exc).__name__}: {exc}", flush=True)
        finally:
            if device == "mps":
                torch.mps.empty_cache()
            gc.collect()
    print(f"Backfill de voz [{tag}] concluído: {done} faixas em {(time.time() - t0) / 60:.1f} min", flush=True)


def collect_audio_files(music_dir: Path) -> List[Tuple[Path, str]]:
    found: List[Tuple[Path, str]] = []
    for root, dirs, files in os.walk(music_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("_dmusic_mix", "_diniz_mix"))
        for fname in sorted(files):
            if fname.startswith("."):
                continue
            ext = os.path.splitext(fname)[1].lower()
            if ext not in AUDIO_EXTS:
                continue
            full = Path(root) / fname
            rel_nfc = norm_rel(str(full.relative_to(music_dir)))
            found.append((full, rel_nfc))
    return found


def sync_existing_to_server(tracks_dir: Path, server_url: str) -> None:
    import requests

    jsons = sorted(tracks_dir.glob("*.json"))
    print(f"Sincronizando {len(jsons)} arquivos existentes com {server_url}...", flush=True)
    ok = 0
    for idx, jp in enumerate(jsons, 1):
        try:
            payload = json.loads(jp.read_text(encoding="utf-8"))
            r = requests.post(f"{server_url.rstrip('/')}/api/ingest", json=payload, timeout=5)
            if r.status_code in (200, 202):
                ok += 1
        except Exception:
            pass
        if idx % 50 == 0 or idx == len(jsons):
            print(f"  [{idx}/{len(jsons)}] sincronizados ({ok} OK)", flush=True)


def _handle_completed(fut: Future, rel_path: str, done_count: int, total_count: int) -> bool:
    try:
        res = fut.result()
        print(
            f"[{done_count}/{total_count}] {res['bpm']:.1f} BPM • {res['camelot']} | "
            f"E={res['energy']:.2f} | demix={res['elapsed_demix']:.1f}s cpu={res['elapsed_cpu']:.1f}s | "
            f"in={res['mix_in']:.1f}s out={res['mix_out']:.1f}s | {res['analyzer']} | {res['ingested']} | {res['rel_path']}",
            flush=True,
        )
        return True
    except Exception as e:
        print(f"[{done_count}/{total_count}] ERRO {rel_path}: {e}", flush=True)
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Analisador Pipeline GPU+CPU allin1 + librosa (DMusic)")
    parser.add_argument("--music-dir", default=os.environ.get("DMUSIC_DIR", os.path.expanduser("~/Soulseek Downloads/complete")))
    parser.add_argument("--server-url", default=os.environ.get("DMUSIC_SERVER_URL", "http://100.125.12.71:4534"))
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--model", default="harmonix-fold0")
    parser.add_argument("--demix-device", default="auto", choices=["auto", "mps", "cpu"])
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--sync-only", action="store_true")
    parser.add_argument("--backfill-vibe", action="store_true", help="Extrai vetor vibe/timbre 24D para toda biblioteca já analisada")
    parser.add_argument("--itunes-dir", default=os.path.expanduser("~/Music/Music/Media.localized/Music"))
    parser.add_argument("--reprocess", action="store_true", help="Refaz só o pós-processamento (grade, tom, energia...) de todos os JSONs")
    parser.add_argument("--out-dir", default="", help="Com --reprocess: grava em outra pasta (ensaio), sem alterar JSONs nem servidor")
    parser.add_argument("--vocals-backfill", action="store_true", help="Roda o demucs nas faixas sem envelope de voz (bar_vocal)")
    parser.add_argument("--only", default="", help="Com --reprocess: só as faixas cujo caminho contém este trecho (aplica correções de tempo_overrides.json)")
    parser.add_argument("--reverse", action="store_true", help="Com --vocals-backfill: percorre a lista ao contrário (2º processo)")
    parser.add_argument("--torch-threads", type=int, default=0, help="Limita as threads do PyTorch (0 = padrão)")
    args = parser.parse_args()

    music_dir = Path(args.music_dir).expanduser().resolve()
    if not music_dir.is_dir():
        raise SystemExit(f"Diretório não encontrado: {music_dir}")

    sync_dir, tracks_dir = ensure_output_dirs(music_dir)
    itunes_tracks = Path(__file__).resolve().parent / "itunes_tracks"
    itunes_music = Path(args.itunes_dir).expanduser()

    if args.reprocess or args.vocals_backfill:
        targets = _library_targets(
            tracks_dir, music_dir,
            itunes_tracks if itunes_tracks.is_dir() else None,
            itunes_music if itunes_music.is_dir() else None,
        )
        if args.only:
            needle = unicodedata.normalize("NFC", args.only).lower()
            targets = [t for t in targets if needle in unicodedata.normalize("NFC", str(t[1])).lower()]
            print(f"--only \"{args.only}\": {len(targets)} faixa(s)", flush=True)
        if args.limit > 0:
            targets = targets[:args.limit]
        if args.reprocess:
            reprocess_library(
                targets, sync_dir, args.server_url, max(1, args.workers),
                out_dir=Path(args.out_dir).expanduser() if args.out_dir else None,
                partial=bool(args.only or args.limit),
            )
        if args.vocals_backfill:
            vocals_backfill(targets, args.server_url, args.demix_device, limit=args.limit,
                            reverse=args.reverse, torch_threads=args.torch_threads)
        return

    if args.backfill_vibe:
        backfill_vibe_library(
            music_dir=music_dir,
            tracks_dir=tracks_dir,
            server_url=args.server_url,
            workers=max(1, args.workers),
            itunes_tracks_dir=itunes_tracks if itunes_tracks.is_dir() else None,
            itunes_music_dir=itunes_music if itunes_music.is_dir() else None,
        )
        return

    if args.sync_only:
        if args.server_url:
            sync_existing_to_server(tracks_dir, args.server_url)
        return

    all_files = collect_audio_files(music_dir)
    pending: List[Tuple[str, str, str, str]] = []
    skipped = 0

    for full, rel_nfc in all_files:
        t_hash = track_hash(rel_nfc)
        jp = tracks_dir / f"{t_hash}.json"
        if not args.force and jp.exists():
            try:
                existing = json.loads(jp.read_text(encoding="utf-8"))
                st = full.stat()
                if existing.get("size") == st.st_size and abs(float(existing.get("mtime", 0)) - st.st_mtime) < 2.0:
                    skipped += 1
                    continue
            except Exception:
                pass
        pending.append((str(full), rel_nfc, str(jp), args.server_url))

    if args.limit > 0:
        pending = pending[:args.limit]

    cpu_count = os.cpu_count() or 10
    cpu_workers = max(1, args.workers)
    cpu_threads = max(1, (cpu_count - 2) // cpu_workers) if cpu_workers >= 4 else max(1, cpu_count // cpu_workers)

    import demucs.api
    import torch

    chosen_demix = args.demix_device
    if chosen_demix == "auto":
        chosen_demix = "mps" if torch.backends.mps.is_available() else "cpu"

    print(
        f"Biblioteca: {len(all_files)} faixas | Já analisadas: {skipped} | Pendentes: {len(pending)} | "
        f"Pipeline: 1 Produtor Demix ({chosen_demix}) -> {cpu_workers} Consumidores CPU ({cpu_threads} threads/worker) | Modelo: {args.model}",
        flush=True,
    )
    if not pending:
        print("Nenhuma música nova para analisar!", flush=True)
        return

    sep = demucs.api.Separator(model="htdemucs", device=chosen_demix, progress=False)
    cpu_sep = None

    t_all = time.time()
    done = 0
    errors = 0
    max_in_flight = cpu_workers + 2
    in_flight: Dict[Future, str] = {}

    ctx = multiprocessing.get_context("spawn")
    with ProcessPoolExecutor(
        max_workers=cpu_workers,
        mp_context=ctx,
        initializer=_init_cpu_worker,
        initargs=(args.model, cpu_threads),
    ) as ex:
        for full_str, rel_nfc, jp_str, server_url in pending:
            # Drena tarefas já concluídas antes de gerar novos stems
            for f_done in [f for f in list(in_flight) if f.done()]:
                r_path = in_flight.pop(f_done)
                done += 1
                if not _handle_completed(f_done, r_path, done, len(pending)):
                    errors += 1

            # Backpressure: mantém no máximo workers+2 conjuntos de stems em /tmp
            while len(in_flight) >= max_in_flight:
                finished, _ = wait(in_flight.keys(), return_when=FIRST_COMPLETED)
                for f_done in finished:
                    r_path = in_flight.pop(f_done)
                    done += 1
                    if not _handle_completed(f_done, r_path, done, len(pending)):
                        errors += 1

            audio_path = Path(full_str)
            t_hash = Path(jp_str).stem
            work_root = Path(f"/tmp/dmusic_mix_worker_{os.getpid()}_{t_hash[:12]}")
            demix_out = work_root / "demix" / "htdemucs" / audio_path.stem
            demix_out.mkdir(parents=True, exist_ok=True)

            t_d0 = time.time()
            demix_out_str = ""
            demix_err = ""
            try:
                try:
                    _, separated = sep.separate_audio_file(audio_path)
                except Exception:
                    if chosen_demix == "mps":
                        if cpu_sep is None:
                            cpu_sep = demucs.api.Separator(model="htdemucs", device="cpu", progress=False)
                        _, separated = cpu_sep.separate_audio_file(audio_path)
                    else:
                        raise

                for stem_name, tensor in separated.items():
                    demucs.api.save_audio(
                        tensor.cpu(),
                        demix_out / f"{stem_name}.wav",
                        samplerate=sep.samplerate,
                    )
                del separated
                demix_out_str = str(demix_out)
            except Exception as exc:
                demix_err = type(exc).__name__
            finally:
                if chosen_demix == "mps":
                    torch.mps.empty_cache()
                gc.collect()

            demix_elapsed = time.time() - t_d0
            cpu_job = (
                full_str,
                rel_nfc,
                jp_str,
                server_url,
                str(work_root),
                demix_out_str,
                demix_elapsed,
                demix_err,
            )
            fut = ex.submit(analyze_cpu_task, cpu_job)
            in_flight[fut] = rel_nfc

        for f_done in as_completed(list(in_flight)):
            r_path = in_flight.pop(f_done)
            done += 1
            if not _handle_completed(f_done, r_path, done, len(pending)):
                errors += 1

    print(
        f"Concluído: {done - errors}/{len(pending)} ok, {errors} erros em {time.time() - t_all:.1f}s",
        flush=True,
    )


if __name__ == "__main__":
    main()
