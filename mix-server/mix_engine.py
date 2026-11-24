import hashlib
import json
import os
import re
import sqlite3
import statistics
import threading
import time
import unicodedata
from typing import Dict, List, Optional, Tuple

NAVIDROME_DB = "/var/lib/navidrome/navidrome.db"
MUSIC_ROOT = "/home/matheus/arquivos_mac/SoulSeek"
SYNC_DIR = "/home/matheus/arquivos_mac/SoulSeek/_diniz_mix"
SYNC_TRACKS_DIR = "/home/matheus/arquivos_mac/SoulSeek/_diniz_mix/tracks"
MIX_DB = "/opt/diniz-mix/mix_data.db"

_db_lock = threading.RLock()


def norm_path(p: str) -> str:
    return unicodedata.normalize("NFC", p.replace("\\", "/").strip("/"))


def track_hash(rel_path: str) -> str:
    return hashlib.sha1(norm_path(rel_path).encode("utf-8")).hexdigest()


def ensure_sync_dirs() -> None:
    os.makedirs(SYNC_TRACKS_DIR, exist_ok=True)
    ndignore = os.path.join(SYNC_DIR, ".ndignore")
    if not os.path.exists(ndignore):
        with open(ndignore, "w", encoding="utf-8") as f:
            f.write("")


def _connect_mix() -> sqlite3.Connection:
    conn = sqlite3.connect(MIX_DB, timeout=15.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn


def init_db() -> None:
    ensure_sync_dirs()
    with _db_lock:
        conn = _connect_mix()
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS tracks (
                    id TEXT PRIMARY KEY,
                    rel_path TEXT NOT NULL,
                    mtime REAL DEFAULT 0,
                    duration REAL NOT NULL,
                    bpm REAL NOT NULL,
                    camelot TEXT NOT NULL,
                    musical_key TEXT DEFAULT '',
                    energy REAL NOT NULL,
                    beats_json TEXT DEFAULT '[]',
                    downbeats_json TEXT DEFAULT '[]',
                    segments_json TEXT DEFAULT '[]',
                    bar_beat_json TEXT DEFAULT '[]',
                    vibe_json TEXT DEFAULT '[]',
                    mix_in_sec REAL NOT NULL,
                    mix_out_sec REAL NOT NULL,
                    analyzer TEXT DEFAULT 'allin1',
                    analyzed_at REAL NOT NULL
                )
                """
            )
            cols = {r[1] for r in conn.execute("PRAGMA table_info(tracks)").fetchall()}
            if "bar_beat_json" not in cols:
                conn.execute("ALTER TABLE tracks ADD COLUMN bar_beat_json TEXT DEFAULT '[]'")
            if "vibe_json" not in cols:
                conn.execute("ALTER TABLE tracks ADD COLUMN vibe_json TEXT DEFAULT '[]'")
            # Análise v2 (grade constante, voz por compasso, origem do tom)
            for col, ddl in (
                ("grid_mode", "TEXT DEFAULT ''"),
                ("bar_vocal_json", "TEXT DEFAULT '[]'"),
                ("key_source", "TEXT DEFAULT ''"),
                ("analysis_version", "INTEGER DEFAULT 1"),
            ):
                if col not in cols:
                    conn.execute(f"ALTER TABLE tracks ADD COLUMN {col} {ddl}")
            conn.commit()
        finally:
            conn.close()


def load_navidrome_map() -> Tuple[int, Dict[str, Tuple[str, float]], Dict[str, Tuple[str, float]]]:
    conn = sqlite3.connect(f"file:{NAVIDROME_DB}?mode=ro", uri=True, timeout=10.0)
    try:
        rows = conn.execute(
            "SELECT id, path, duration FROM media_file WHERE missing = 0"
        ).fetchall()
    finally:
        conn.close()

    nfc_map: Dict[str, Tuple[str, float]] = {}
    lower_map: Dict[str, Tuple[str, float]] = {}
    for song_id, raw_path, dur in rows:
        n = norm_path(raw_path or "")
        if not n:
            continue
        info = (str(song_id), float(dur or 0.0))
        nfc_map[n] = info
        lower_map[n.lower()] = info
    return len(rows), nfc_map, lower_map


def _resolve_song(
    rel_path: str,
    nfc_map: Dict[str, Tuple[str, float]],
    lower_map: Dict[str, Tuple[str, float]],
) -> Optional[Tuple[str, float]]:
    n = norm_path(rel_path)
    hit = nfc_map.get(n)
    if hit:
        return hit
    return lower_map.get(n.lower())


def _robust_bpm_from_beats(beats: List[float], fallback_bpm: float) -> float:
    """BPM por regressão linear sobre as batidas que caem numa grade constante.

    O allin1 entrega batidas quantizadas em 10 ms; a mediana dos intervalos (método antigo) transforma
    140.000 em 139.535 (60/0.43). A regressão sobre centenas de batidas recupera o valor exato.
    """
    b = sorted(float(x) for x in beats)
    if len(b) < 16:
        return round(float(fallback_bpm or 120.0), 4)
    ibi = [b[i + 1] - b[i] for i in range(len(b) - 1)]
    med = statistics.median(ibi)
    if med <= 0.2:
        return round(float(fallback_bpm or 120.0), 4)
    # Maior trecho contínuo sem falhas (intervalo a ±8% da mediana) como estimativa inicial
    best, best_rng, cur, start = 0, (0, len(b) - 1), 0, 0
    for i, x in enumerate(ibi):
        if abs(x - med) <= 0.08 * med:
            if cur == 0:
                start = i
            cur += 1
            if cur > best:
                best, best_rng = cur, (start, i + 1)
        else:
            cur = 0

    def fit(ks: List[float], ts: List[float]) -> Tuple[float, float]:
        n = len(ks)
        mk, mt = sum(ks) / n, sum(ts) / n
        sxx = sum((k - mk) ** 2 for k in ks) or 1e-9
        slope = sum((k - mk) * (t - mt) for k, t in zip(ks, ts)) / sxx
        return slope, mt - slope * mk

    lo, hi = best_rng
    period, t0 = fit(list(range(hi - lo + 1)), b[lo:hi + 1])
    t0 -= lo * period
    for _ in range(4):
        ks, ts = [], []
        for t in b:
            k = round((t - t0) / period)
            if abs(t - (t0 + k * period)) <= 0.035:
                ks.append(k)
                ts.append(t)
        if len(ks) < 8:
            break
        period, t0 = fit(ks, ts)
    exact = 60.0 / period if period > 0 else float(fallback_bpm or 120.0)
    return round(exact, 4)


def _track_bpm(payload_bpm: float, beats: List[float], analysis_version: int) -> float:
    """Análise v2 já traz o BPM exato da grade constante; dados antigos passam pela regressão robusta."""
    if analysis_version >= 2 and payload_bpm and payload_bpm > 0:
        return round(float(payload_bpm), 4)
    return _robust_bpm_from_beats(beats, float(payload_bpm or 120.0))


def _row_from_payload(payload: dict, song_id: str, rel: str, nav_dur: float, now: float) -> tuple:
    duration = float(payload.get("duration") or nav_dur or 0.0)
    if duration <= 0:
        duration = float(nav_dur or 180.0)
    beats = payload.get("beats") or []
    version = int(payload.get("analysis_version") or 1)
    return (
        song_id,
        rel,
        float(payload.get("mtime") or 0.0),
        duration,
        _track_bpm(float(payload.get("bpm") or 0.0), beats, version),
        str(payload.get("camelot") or "8A"),
        str(payload.get("musical_key") or ""),
        float(payload.get("energy") if payload.get("energy") is not None else 0.5),
        json.dumps(beats),
        json.dumps(payload.get("downbeats") or []),
        json.dumps(payload.get("segments") or []),
        json.dumps(payload.get("bar_beat") or []),
        json.dumps(payload.get("vibe") or []),
        float(payload.get("mix_in_sec") or 0.0),
        float(payload.get("mix_out_sec") or max(duration * 0.5, duration - 10.0)),
        str(payload.get("analyzer") or "allin1"),
        float(payload.get("analyzed_at") or now),
        str(payload.get("grid_mode") or ""),
        json.dumps(payload.get("bar_vocal") or []),
        str(payload.get("key_source") or ""),
        version,
    )


_UPSERT_SQL = """
    INSERT OR REPLACE INTO tracks (
        id, rel_path, mtime, duration, bpm, camelot, musical_key,
        energy, beats_json, downbeats_json, segments_json, bar_beat_json, vibe_json,
        mix_in_sec, mix_out_sec, analyzer, analyzed_at,
        grid_mode, bar_vocal_json, key_source, analysis_version
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


def upsert_track_payload(
    payload: dict,
    nav_maps: Optional[Tuple[int, Dict[str, Tuple[str, float]], Dict[str, Tuple[str, float]]]] = None,
    write_file: bool = True,
) -> Optional[str]:
    rel = norm_path(payload.get("rel_path", ""))
    if not rel:
        return None

    if write_file:
        ensure_sync_dirs()
        dst = os.path.join(SYNC_TRACKS_DIR, f"{track_hash(rel)}.json")
        tmp = f"{dst}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, dst)

    if nav_maps is None:
        nav_maps = load_navidrome_map()
    _, nfc_map, lower_map = nav_maps
    resolved = _resolve_song(rel, nfc_map, lower_map)
    if not resolved:
        return None
    song_id, nav_dur = resolved
    row = _row_from_payload(payload, song_id, rel, nav_dur, time.time())
    with _db_lock:
        conn = _connect_mix()
        try:
            conn.execute(_UPSERT_SQL, row)
            conn.commit()
        finally:
            conn.close()
    return song_id


# mtime de cada JSON já sincronizado: o worker periódico (a cada 60 s) só relê arquivos novos/alterados
_synced_mtimes: Dict[str, float] = {}


def sync_from_folder(full: bool = False) -> dict:
    ensure_sync_dirs()
    nav_maps = load_navidrome_map()
    total_nav, nfc_map, lower_map = nav_maps

    files = [f for f in os.listdir(SYNC_TRACKS_DIR) if f.endswith(".json") and not f.startswith(".")]
    matched = 0
    changed = 0
    rows_to_insert = []
    now = time.time()
    seen_mtimes: Dict[str, float] = {}

    for fname in files:
        fpath = os.path.join(SYNC_TRACKS_DIR, fname)
        try:
            mtime = os.path.getmtime(fpath)
        except OSError:
            continue
        if not full and _synced_mtimes.get(fname) == mtime:
            seen_mtimes[fname] = mtime
            matched += 1
            continue
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                payload = json.load(f)
        except Exception:
            continue
        rel = norm_path(payload.get("rel_path", ""))
        if not rel:
            continue
        resolved = _resolve_song(rel, nfc_map, lower_map)
        if not resolved:
            continue
        matched += 1
        changed += 1
        seen_mtimes[fname] = mtime
        song_id, nav_dur = resolved
        rows_to_insert.append(_row_from_payload(payload, song_id, rel, nav_dur, now))

    with _db_lock:
        conn = _connect_mix()
        try:
            if rows_to_insert:
                conn.executemany(_UPSERT_SQL, rows_to_insert)
                conn.commit()
            analyzed = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        finally:
            conn.close()
    _synced_mtimes.clear()
    _synced_mtimes.update(seen_mtimes)

    return {
        "total_navidrome": total_nav,
        "analyzed": analyzed,
        "files_seen": len(files),
        "matched": matched,
        "updated": changed,
    }


def get_health_counts() -> Tuple[int, int]:
    conn_nav = sqlite3.connect(f"file:{NAVIDROME_DB}?mode=ro", uri=True, timeout=10.0)
    try:
        total_nav = conn_nav.execute("SELECT COUNT(*) FROM media_file WHERE missing = 0").fetchone()[0]
    finally:
        conn_nav.close()

    with _db_lock:
        conn = _connect_mix()
        try:
            analyzed = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        finally:
            conn.close()
    return int(total_nav), int(analyzed)


def list_tracks_summary() -> List[dict]:
    with _db_lock:
        conn = _connect_mix()
        try:
            rows = conn.execute(
                """
                SELECT id, bpm, camelot, musical_key, energy, mix_in_sec, mix_out_sec, duration, analyzer, vibe_json
                FROM tracks
                """
            ).fetchall()
        finally:
            conn.close()
    out = []
    for r in rows:
        d = dict(r)
        raw_v = d.pop("vibe_json", None)
        if raw_v and raw_v != "[]":
            try:
                v = json.loads(raw_v)
                if isinstance(v, list) and len(v) > 0:
                    d["vibe"] = v
            except Exception:
                pass
        out.append(d)
    return out


def get_track(song_id: str) -> Optional[dict]:
    with _db_lock:
        conn = _connect_mix()
        try:
            row = conn.execute("SELECT * FROM tracks WHERE id = ?", (song_id,)).fetchone()
        finally:
            conn.close()
    return dict(row) if row else None


def _parse_camelot(code: str) -> Optional[Tuple[int, str]]:
    m = re.match(r"^\s*(1[0-2]|[1-9])\s*([AB])\s*$", str(code or "").upper())
    if not m:
        return None
    return int(m.group(1)), m.group(2)


def _camelot_score(key_a: str, key_b: str) -> float:
    pa = _parse_camelot(key_a)
    pb = _parse_camelot(key_b)
    if not pa or not pb:
        return 0.0
    na, la = pa
    nb, lb = pb
    raw_diff = abs(na - nb)
    circ_diff = min(raw_diff, 12 - raw_diff)
    same_letter = (la == lb)
    if circ_diff == 0 and same_letter:
        return 35.0
    if (circ_diff == 0 and not same_letter) or (circ_diff == 1 and same_letter):
        return 30.0
    if circ_diff == 2 and same_letter:
        return 20.0
    return 0.0


def _build_downbeat_grid(raw_dbs: List[float], beats: List[float], dur: float, bpm: float) -> List[float]:
    dbs = sorted(set(round(float(x), 4) for x in raw_dbs if 0.0 <= float(x) < dur))
    if len(dbs) >= 12:
        return dbs
    if len(beats) >= 16:
        return [round(float(x), 4) for x in beats[::4] if 0.0 <= float(x) < dur]
    bar = 4.0 * 60.0 / max(bpm, 60.0)
    out = []
    t = 0.0
    while t < dur - 0.1:
        out.append(round(t, 4))
        t += bar
    return out


def _normalize_bar_beats(raw_bb: List[float], num_dbs: int) -> List[float]:
    if not raw_bb:
        return [0.75] * num_dbs
    out = [float(x) for x in raw_bb[:num_dbs]]
    while len(out) < num_dbs:
        out.append(out[-1] if out else 0.75)
    return out


def _bar_beat_mean(bb: List[float], idx_start: int, count: int) -> float:
    if not bb or count <= 0:
        return 0.75
    lo = max(0, min(len(bb) - 1, idx_start))
    hi = max(lo + 1, min(len(bb), lo + count))
    seg = bb[lo:hi]
    return sum(seg) / len(seg) if seg else 0.75


def _nearest_db_idx(target: float, dbs: List[float], lo_idx: int = 0, hi_idx: Optional[int] = None) -> int:
    if not dbs:
        return 0
    if hi_idx is None:
        hi_idx = len(dbs) - 1
    lo_idx = max(0, lo_idx)
    hi_idx = min(len(dbs) - 1, max(lo_idx, hi_idx))
    return min(range(lo_idx, hi_idx + 1), key=lambda i: abs(dbs[i] - target))


def _section_at(t: float, segs: List[dict]) -> str:
    for s in segs:
        lbl = str(s.get("label", "")).lower()
        if lbl in ("start", "end"):
            continue
        if float(s.get("start", 0.0)) - 0.05 <= t < float(s.get("end", 0.0)) + 0.05:
            return lbl
    return "inst"


def _dominant_section(start_t: float, end_t: float, segs: List[dict]) -> str:
    totals: Dict[str, float] = {}
    for s in segs:
        lbl = str(s.get("label", "")).lower()
        if lbl in ("start", "end"):
            continue
        ov = min(end_t, float(s.get("end", 0.0))) - max(start_t, float(s.get("start", 0.0)))
        if ov > 0:
            totals[lbl] = totals.get(lbl, 0.0) + ov
    if not totals:
        return _section_at(0.5 * (start_t + end_t), segs)
    return max(totals.items(), key=lambda kv: kv[1])[0]


def _vocal_overlap_ratio(start_t: float, end_t: float, segs: List[dict]) -> float:
    dur = max(end_t - start_t, 0.1)
    voc = 0.0
    for s in segs:
        lbl = str(s.get("label", "")).lower()
        if lbl not in ("verse", "chorus"):
            continue
        ov = min(end_t, float(s.get("end", 0.0))) - max(start_t, float(s.get("start", 0.0)))
        if ov > 0:
            voc += ov
    return voc / dur


def _vocal_ratio(start_t: float, end_t: float, segs: List[dict], dbs: List[float], bar_vocal: List[float]) -> float:
    """Fração da janela com voz. Usa a presença real de voz por compasso (stem de voz do demucs) quando existe;
    senão, os rótulos verse/chorus do allin1 (que não medem voz de fato)."""
    if bar_vocal and dbs:
        flags = [bar_vocal[i] >= 0.5 for i in range(min(len(dbs), len(bar_vocal))) if start_t - 0.05 <= dbs[i] < end_t - 0.05]
        if flags:
            return sum(flags) / len(flags)
    return _vocal_overlap_ratio(start_t, end_t, segs)


def _intro_end_sec(segs: List[dict], dur: float) -> float:
    end_t = 0.0
    for s in segs:
        lbl = str(s.get("label", "")).lower()
        st = float(s.get("start", 0.0))
        en = float(s.get("end", 0.0))
        if lbl == "start":
            end_t = max(end_t, en)
        elif lbl == "intro" and st <= end_t + 1.0 and en <= dur * 0.55:
            end_t = max(end_t, en)
        elif st > end_t + 1.0 or lbl not in ("start", "intro"):
            break
    return end_t


def _choose_mix_bars(
    bpm_a: float,
    dur_a: float,
    segs_a: List[dict],
    dur_b: float,
    segs_b: List[dict],
    c_score: float,
    is_beatmatch: bool,
    bars_override: Optional[int] = None,
) -> int:
    if bars_override in (2, 4, 8, 16):
        return int(bars_override)
    if not is_beatmatch:
        return 8 if bpm_a >= 120.0 and dur_a >= 120.0 else 4
    if bpm_a < 95.0:
        return 4
    bar_sec = 4.0 * 60.0 / max(bpm_a, 60.0)
    if dur_a < 130.0 or dur_b < 130.0 or (8.0 * bar_sec) > min(dur_a, dur_b) * 0.24:
        return 4
    has_long_out_a = any(
        str(s.get("label", "")).lower() in ("inst", "outro")
        and float(s.get("end", 0)) - float(s.get("start", 0)) >= 14.0 * bar_sec
        and float(s.get("start", 0)) >= dur_a * 0.48
        for s in segs_a
    )
    has_long_in_b = any(
        str(s.get("label", "")).lower() in ("intro", "inst")
        and float(s.get("end", 0)) - float(s.get("start", 0)) >= 14.0 * bar_sec
        and float(s.get("end", 0)) <= dur_b * 0.52
        for s in segs_b
    )
    if dur_a >= 165.0 and dur_b >= 165.0:
        if c_score >= 28.0 and has_long_out_a and has_long_in_b:
            return 16
        if bpm_a >= 132.0 and c_score >= 20.0 and (has_long_out_a or has_long_in_b):
            return 16
    return 8


def _choose_mix_effects(
    is_beatmatch: bool,
    c_score: float,
    voc_a: bool,
    voc_b: bool,
    beat_b_during: float,
    beat_b_at_drop: float,
    sec_a: str,
    sec_b: str,
    mix_bars: int,
    energy_a: float,
    energy_b: float,
) -> Tuple[str, str, str, bool, float]:
    """
    Seleciona inteligentemente:
      - volume_curve ('overlap' por padrão, ou 'fade_in_cut_out' quando B entra com voz/build-up e o beat estoura no final)
      - eq_style (se B entra só com voz sem batida durante a janela e a batida entra no drop, usa 'end_bass_swap')
      - filter_style
      - reverb_tail
      - bass_swap_at_progress (0.50 padrão, ou 0.82 se B for vocal teaser -> beat drop)
    """
    if not is_beatmatch:
        return ("crossfade_quick_out", "center_bass_swap", "final_noise_out", True, 0.50)

    if mix_bars == 2:
        return ("fade_in_1bar_cut_out", "quick_bass_cut", "hp_out", False, 0.50)

    # B entra só com voz/build-up e a batida dela chega no fim: Sobrepor com a troca de graves no fim (0.82),
    # quando o grave de B finalmente aparece. (Antes era "fade_in_cut_out", que o app reescrevia para "overlap".)
    is_vocal_teaser_to_beat_drop = (beat_b_during < 0.45 and beat_b_at_drop >= 0.48)
    if is_vocal_teaser_to_beat_drop:
        return ("overlap", "end_bass_swap", "partial_hp_out", False, 0.82)

    # "Sobrepor" é a curva padrão do app (B sobe cedo, convivência, A sai em cosseno no último terço);
    # vozes simultâneas são tratadas pelo EQ de 3 bandas abaixo, não por corte de volume.
    volume_curve = "overlap"

    if voc_a or voc_b or c_score == 0.0:
        eq_style = "three_band"
    elif "→chorus" in sec_b and energy_b >= 0.88:
        eq_style = "quick_bass_cut"
    else:
        eq_style = "center_bass_swap"

    if c_score == 0.0:
        filter_style = "lp_in_hp_out"
    elif voc_a and not voc_b:
        filter_style = "partial_hp_out"
    elif sec_a in ("outro", "break", "bridge") and energy_a > energy_b + 0.18:
        filter_style = "hp_in_lp_out"
    else:
        filter_style = "hp_in_hp_out"

    reverb_tail = (filter_style == "final_noise_out")
    return (volume_curve, eq_style, filter_style, reverb_tail, 0.50)


def _collect_exit_candidates_a(
    db_a: List[float],
    segs_a: List[dict],
    bb_a: List[float],
    dur_a: float,
    mix_bars: int,
    mix_out_hint: float = 0.0,
    bv_a: Optional[List[float]] = None,
) -> List[Tuple[int, float, str, float, float, float, str]]:
    max_idx = len(db_a) - 1 - mix_bars
    if max_idx < 0:
        return []

    # A toca quase inteira e sai no outro (como o Automix do rekordbox). Antes a faixa ideal era 56–78%,
    # o que cortava o último terço das músicas (mediana medida: saída em 66% da faixa).
    if dur_a >= 210.0:
        pass_windows = ((0.62, 0.95), (0.52, 0.96))
        sweet_lo, sweet_hi = 0.72, 0.92
        fracs = (0.74, 0.80, 0.86, 0.90)
    elif dur_a >= 140.0:
        pass_windows = ((0.64, 0.95), (0.56, 0.96))
        sweet_lo, sweet_hi = 0.74, 0.92
        fracs = (0.76, 0.82, 0.88, 0.91)
    else:
        pass_windows = ((0.68, 0.95), (0.58, 0.96))
        sweet_lo, sweet_hi = 0.76, 0.93
        fracs = (0.78, 0.84, 0.88, 0.92)
    bar_sec = statistics.median([db_a[i + 1] - db_a[i] for i in range(len(db_a) - 1)]) if len(db_a) > 2 else 2.0

    cand_indices = set()
    for lo_pct, hi_pct in pass_windows:
        lo_t = dur_a * lo_pct
        hi_t = dur_a * hi_pct
        valid_idxs = [i for i in range(max_idx + 1) if lo_t <= db_a[i] <= hi_t and db_a[i + mix_bars] <= dur_a - 0.3]
        if not valid_idxs:
            continue

        for s in segs_a:
            lbl = str(s.get("label", "")).lower()
            if lbl in ("start", "end"):
                continue
            for t_edge in (float(s.get("start", 0)), float(s.get("end", 0))):
                if lo_t <= t_edge <= hi_t:
                    cand_indices.add(_nearest_db_idx(t_edge, db_a, valid_idxs[0], valid_idxs[-1]))

            st = float(s.get("start", 0))
            en = float(s.get("end", 0))
            if lbl in ("inst", "outro", "break", "bridge") and (en - st) >= 18.0:
                idx0 = _nearest_db_idx(max(st, lo_t), db_a, valid_idxs[0], valid_idxs[-1])
                idx_end = _nearest_db_idx(min(en, hi_t), db_a, valid_idxs[0], valid_idxs[-1])
                for cur in range(idx0, idx_end + 1, 4):
                    cand_indices.add(cur)

        for i in range(valid_idxs[0], valid_idxs[-1] + 1, 4):
            if _bar_beat_mean(bb_a, i, mix_bars) >= 0.50:
                cand_indices.add(i)

        for frac in fracs:
            cand_indices.add(_nearest_db_idx(dur_a * frac, db_a, valid_idxs[0], valid_idxs[-1]))

        # Ponto de saída estrutural escolhido pelo analyzer (início do outro / fim do último refrão, no downbeat)
        if mix_out_hint > 0 and lo_t <= mix_out_hint <= hi_t:
            cand_indices.add(_nearest_db_idx(mix_out_hint, db_a, valid_idxs[0], valid_idxs[-1]))

        if cand_indices:
            break

    if not cand_indices:
        cand_indices.add(max(0, min(max_idx, int(len(db_a) * 0.72))))

    half = max(1, mix_bars // 2)
    # Seções da análise v2 caem exatamente no downbeat: tolerância de 1/4 de compasso (antes 2.2 s, que a 140 BPM
    # aceitava um compasso inteiro antes da seção como "início de seção")
    seg_tol = max(0.25 * bar_sec, 0.15)
    seg_start_idxs = sorted(
        _nearest_db_idx(float(s.get("start", 0.0)), db_a)
        for s in segs_a if str(s.get("label", "")).lower() not in ("start", "end")
    )
    scored: List[Tuple[int, float, str, float, float, float, str]] = []
    for idx in sorted(cand_indices):
        t_s = db_a[idx]
        t_e = db_a[idx + mix_bars]
        pct = t_s / max(dur_a, 1.0)
        sec_before = _section_at(t_s - 0.8, segs_a)
        sec_at = _section_at(t_s + 0.5, segs_a)
        dom = _dominant_section(t_s, t_e, segs_a)
        vocal_ratio = _vocal_ratio(t_s, t_e, segs_a, db_a, bv_a or [])
        beat_strength_a = _bar_beat_mean(bb_a, idx, mix_bars)
        beat_a_h1 = _bar_beat_mean(bb_a, idx, half)
        beat_a_h2 = _bar_beat_mean(bb_a, idx + half, max(1, mix_bars - half))

        score = 0.0
        is_seg_start = any(abs(float(s.get("start", -99)) - t_s) <= seg_tol and str(s.get("label", "")).lower() not in ("start", "end") for s in segs_a)
        is_chorus_end = any(abs(float(s.get("end", -99)) - t_s) <= seg_tol and str(s.get("label", "")).lower() == "chorus" for s in segs_a)

        # Frase: o mix deve começar num múltiplo de 8 compassos desde o início da seção (como as frases do rekordbox)
        prev_starts = [si for si in seg_start_idxs if si <= idx]
        if prev_starts:
            bars_since = idx - prev_starts[-1]
            if bars_since % 8 == 0:
                score += 6.0
            elif bars_since % 4 == 0:
                score += 2.0
            else:
                score -= 8.0

        if is_seg_start and sec_before in ("chorus", "verse") and sec_at in ("outro", "inst", "break", "bridge", "solo") and sweet_lo <= pct <= sweet_hi:
            score += 24.0
        elif (is_chorus_end or (is_seg_start and sec_at in ("outro", "inst", "break", "bridge"))) and sweet_lo <= pct <= sweet_hi:
            score += 15.0
        elif is_seg_start and sweet_lo <= pct <= sweet_hi:
            score += 8.0
        if sec_at == "outro":
            score += 10.0
        if mix_out_hint > 0 and abs(t_s - mix_out_hint) <= 1.5 * bar_sec:
            score += 16.0

        if beat_strength_a >= 0.55:
            score += 12.0
        elif beat_strength_a < 0.30:
            score -= 18.0

        if sweet_lo <= pct <= sweet_hi:
            score += 20.0
        elif (sweet_lo - 0.06) <= pct <= min(0.95, sweet_hi + 0.03):
            score += 8.0
        else:
            score -= 22.0

        if (dur_a - t_e) < 1.5 or pct > 0.95:
            score -= 18.0
        if vocal_ratio > 0.35:
            score -= 8.0
        if sec_before == "chorus" and sec_at == "chorus":
            score -= 6.0

        scored.append((idx, score, dom, beat_strength_a, beat_a_h1, beat_a_h2, sec_at))

    return scored


def _run_entry_pass_b(
    db_b: List[float],
    segs_b: List[dict],
    bb_b: List[float],
    dur_b: float,
    mix_bars: int,
    max_entry_t: float,
    max_mix_end_t: float,
    bv_b: Optional[List[float]] = None,
) -> List[Tuple[int, float, str, bool, float, float]]:
    max_idx = len(db_b) - 1 - mix_bars
    if max_idx < 0:
        return []

    valid_idxs = [i for i in range(max_idx + 1) if db_b[i] <= max_entry_t and db_b[i + mix_bars] <= max_mix_end_t]
    if not valid_idxs:
        valid_idxs = [0]
    valid_set = set(valid_idxs)

    cand_map: Dict[int, Tuple[float, str]] = {}

    def register_cand(idx: int, bonus: float, label: str) -> None:
        if idx not in valid_set:
            return
        prev = cand_map.get(idx)
        if not prev or bonus > prev[0]:
            cand_map[idx] = (bonus, label)

    beat_drop_idxs: List[int] = []
    for k in range(len(db_b) - 2):
        if db_b[k] > max_mix_end_t + 2.0:
            break
        cur_beat = _bar_beat_mean(bb_b, k, 2)
        prev_beat = _bar_beat_mean(bb_b, max(0, k - 2), 2) if k >= 2 else 0.0
        if cur_beat >= 0.50 and (k == 0 or prev_beat < 0.44 or (cur_beat - prev_beat) >= 0.20):
            beat_drop_idxs.append(k)

    for k in beat_drop_idxs:
        sec_at_k = _section_at(db_b[k] + 0.3, segs_b)
        after_end_beat = _bar_beat_mean(bb_b, k + mix_bars, 2)
        if after_end_beat >= 0.48:
            register_cand(k, 30.0, f"beat({sec_at_k})")
        else:
            register_cand(k, 26.0, f"beat→voz({sec_at_k})")

        entry_before_drop = k - mix_bars
        if entry_before_drop >= 0:
            sec_in = _dominant_section(db_b[entry_before_drop], db_b[k], segs_b)
            register_cand(entry_before_drop, 32.0, f"{sec_in}→beat({sec_at_k})")

    for s in segs_b:
        lbl = str(s.get("label", "")).lower()
        if lbl in ("start", "end"):
            continue
        st = float(s.get("start", 0.0))
        if st > max_mix_end_t + 2.0:
            continue
        arr_idx = _nearest_db_idx(st, db_b, 0, len(db_b) - 1)
        beat_at_arr = _bar_beat_mean(bb_b, arr_idx, 3)

        if lbl in ("chorus", "verse", "inst") and st >= 2.0:
            entry_idx = arr_idx - mix_bars
            if beat_at_arr >= 0.48 and entry_idx >= 0:
                sec_in = _dominant_section(db_b[entry_idx], db_b[arr_idx], segs_b)
                register_cand(entry_idx, 26.0 if lbl == "chorus" else 22.0, f"{sec_in}→{lbl}")
            if beat_at_arr >= 0.52:
                register_cand(arr_idx, 24.0, f"beat({lbl})")

    for i in valid_idxs[::4]:
        if _bar_beat_mean(bb_b, i, mix_bars) >= 0.50:
            sec_i = _section_at(db_b[i] + 0.3, segs_b)
            register_cand(i, 20.0, f"beat({sec_i})")

    if 0 not in cand_map and 0 in valid_set:
        register_cand(0, 10.0, _dominant_section(db_b[0], db_b[min(len(db_b) - 1, mix_bars)], segs_b))

    scored: List[Tuple[int, float, str, bool, float, float]] = []
    for idx, (base_bonus, sec_label) in sorted(cand_map.items()):
        t_in = db_b[idx]
        t_end = db_b[idx + mix_bars]
        vocal_b = _vocal_ratio(t_in, t_end, segs_b, db_b, bv_b or []) > 0.35

        beat_during = _bar_beat_mean(bb_b, idx, mix_bars)
        beat_at_drop = _bar_beat_mean(bb_b, idx + mix_bars, 3)

        pct_in = t_in / max(dur_b, 1.0)
        if pct_in <= 0.10 and t_in <= 20.0:
            early_bonus = 28.0
        elif pct_in <= 0.18:
            early_bonus = 28.0 - 16.0 * ((pct_in - 0.10) / 0.08)
        elif pct_in <= 0.25:
            early_bonus = 12.0 - 16.0 * ((pct_in - 0.18) / 0.07)
        else:
            early_bonus = -4.0 - 2.5 * (pct_in * 100.0 - 25.0)

        score = base_bonus + early_bonus

        if beat_during >= 0.52 and beat_at_drop >= 0.48:
            score += 22.0
        elif beat_during >= 0.52 and beat_at_drop < 0.48:
            score += 14.0
        elif beat_during < 0.45 and beat_at_drop >= 0.50:
            score += 20.0
        elif beat_during < 0.42 and beat_at_drop < 0.45:
            score -= 55.0

        if not vocal_b and beat_during >= 0.50:
            score += 8.0

        scored.append((idx, score, sec_label, vocal_b, beat_during, beat_at_drop))

    return scored


def _collect_entry_candidates_b(
    db_b: List[float],
    segs_b: List[dict],
    bb_b: List[float],
    dur_b: float,
    bpm_b: float,
    mix_bars: int,
    bv_b: Optional[List[float]] = None,
) -> List[Tuple[int, float, str, bool, float, float]]:
    """
    Encontra os melhores pontos de entrada no início da Música B (respeitando teto rígido para não pular metade da faixa)
    e mantendo variedade de candidatos cedo para avaliação conjunta A + B.
    """
    bar_sec_b = 4.0 * 60.0 / max(bpm_b, 60.0)
    max_entry_1 = min(dur_b * 0.24, 42.0)
    max_end_1 = min(dur_b * 0.38, max_entry_1 + mix_bars * bar_sec_b + 3.0)
    pass1 = _run_entry_pass_b(db_b, segs_b, bb_b, dur_b, mix_bars, max_entry_1, max_end_1, bv_b)

    has_good_beat = any((c[4] >= 0.45 or c[5] >= 0.48) for c in pass1)
    if has_good_beat:
        return pass1

    max_entry_2 = min(dur_b * 0.34, 60.0)
    max_end_2 = min(dur_b * 0.48, max_entry_2 + mix_bars * bar_sec_b + 3.0)
    pass2 = _run_entry_pass_b(db_b, segs_b, bb_b, dur_b, mix_bars, max_entry_2, max_end_2, bv_b)
    return pass2 or pass1


def compute_transition(track_a: dict, track_b: dict, bars_override: Optional[int] = None) -> dict:
    beats_a = json.loads(track_a.get("beats_json") or "[]")
    beats_b = json.loads(track_b.get("beats_json") or "[]")
    segs_a = json.loads(track_a.get("segments_json") or "[]")
    segs_b = json.loads(track_b.get("segments_json") or "[]")

    dur_a = float(track_a.get("duration") or 180.0)
    dur_b = float(track_b.get("duration") or 180.0)
    # O BPM gravado já é exato (grade constante da análise v2 ou regressão robusta nos dados antigos)
    bpm_a = float(track_a.get("bpm") or 0.0) or _robust_bpm_from_beats(beats_a, 120.0)
    bpm_b = float(track_b.get("bpm") or 0.0) or _robust_bpm_from_beats(beats_b, 120.0)

    db_a = _build_downbeat_grid(json.loads(track_a.get("downbeats_json") or "[]"), beats_a, dur_a, bpm_a)
    db_b = _build_downbeat_grid(json.loads(track_b.get("downbeats_json") or "[]"), beats_b, dur_b, bpm_b)

    bb_a = _normalize_bar_beats(json.loads(track_a.get("bar_beat_json") or "[]"), len(db_a))
    bb_b = _normalize_bar_beats(json.loads(track_b.get("bar_beat_json") or "[]"), len(db_b))
    bv_a = json.loads(track_a.get("bar_vocal_json") or "[]")
    bv_b = json.loads(track_b.get("bar_vocal_json") or "[]")
    mix_out_hint_a = float(track_a.get("mix_out_sec") or 0.0)

    energy_a = float(track_a["energy"] if track_a.get("energy") is not None else 0.5)
    energy_b = float(track_b["energy"] if track_b.get("energy") is not None else 0.5)

    eff_bpm_b = min([bpm_b, bpm_b * 2.0, bpm_b * 0.5], key=lambda c: abs(c - bpm_a) / max(bpm_a, 1e-6))
    diff_pct = abs(eff_bpm_b - bpm_a) / max(bpm_a, 1e-6)
    is_beatmatch = (diff_pct <= 0.15) and (bpm_a >= 50.0) and (bpm_b >= 50.0)
    c_score = _camelot_score(track_a.get("camelot", ""), track_b.get("camelot", ""))

    mix_bars = _choose_mix_bars(bpm_a, dur_a, segs_a, dur_b, segs_b, c_score, is_beatmatch, bars_override=bars_override)
    cands_a = _collect_exit_candidates_a(db_a, segs_a, bb_a, dur_a, mix_bars, mix_out_hint_a, bv_a)
    cands_b = _collect_entry_candidates_b(db_b, segs_b, bb_b, dur_b, bpm_b, mix_bars, bv_b)

    if (not cands_a or not cands_b) and mix_bars > 4:
        mix_bars = 4
        cands_a = _collect_exit_candidates_a(db_a, segs_a, bb_a, dur_a, mix_bars, mix_out_hint_a, bv_a)
        cands_b = _collect_entry_candidates_b(db_b, segs_b, bb_b, dur_b, bpm_b, mix_bars, bv_b)

    top_a = sorted(cands_a, key=lambda c: c[1], reverse=True)[:16]
    top_b = sorted(cands_b, key=lambda c: c[1], reverse=True)[:16]
    nom_ratio = eff_bpm_b / max(bpm_a, 1e-6)

    best_pair = None
    best_total = -1e9
    best_voc_a = False
    best_voc_b = False
    best_beat_b_during = 0.75
    best_beat_b_drop = 0.75

    for idx_a, score_a, sec_a, beat_a, beat_a_h1, beat_a_h2, sec_at_a in top_a:
        voc_a = _vocal_ratio(db_a[idx_a], db_a[idx_a + mix_bars], segs_a, db_a, bv_a) > 0.35
        a_win = bb_a[idx_a : idx_a + mix_bars]
        span_a_cand = max(min(dur_a - 0.25, float(db_a[idx_a + mix_bars])) - float(db_a[idx_a]), 2.0)

        for idx_b, score_b, sec_b, voc_b, beat_b_during, beat_b_drop in top_b:
            b_win = bb_b[idx_b : idx_b + mix_bars]
            n_win = min(len(a_win), len(b_win))
            half = max(1, n_win // 2)
            if n_win >= 2:
                b_h2 = sum(b_win[half:n_win]) / max(1, n_win - half)
                min_combined = min(max(a_win[j], b_win[j]) for j in range(n_win))
            else:
                b_h2 = beat_b_during
                min_combined = max(beat_a, beat_b_during)

            pair_adj = 0.0
            if min_combined < 0.35:
                pair_adj -= 32.0

            if beat_a_h1 >= 0.50 and beat_a_h2 < beat_a_h1 - 0.10 and (b_h2 >= 0.55 or beat_b_drop >= 0.56):
                pair_adj += 32.0
            elif beat_a >= 0.54 and beat_b_during >= 0.54 and min_combined >= 0.48:
                pair_adj += 28.0

            if beat_b_during < 0.45 and beat_b_drop >= 0.50:
                if beat_a_h1 >= 0.52 and beat_a_h2 >= 0.46 and not voc_a:
                    pair_adj += 34.0
                elif voc_a or beat_a < 0.42:
                    pair_adj -= 38.0

            if voc_a and voc_b:
                pair_adj -= 36.0
            elif not voc_a and not voc_b:
                pair_adj += 18.0
            elif (voc_a != voc_b) and ((voc_a and beat_b_during >= 0.52) or (voc_b and beat_a >= 0.52)):
                pair_adj += 6.0

            if is_beatmatch:
                span_b_cand = max(float(db_b[idx_b + mix_bars]) - float(db_b[idx_b]), 2.0)
                raw_gr = span_a_cand / span_b_cand
                gc = min([raw_gr, raw_gr * 2.0, raw_gr * 0.5], key=lambda r: abs(1.0 - r))
                g_err = abs(gc - nom_ratio)
                if g_err <= 0.012:
                    pair_adj += 14.0
                elif g_err > 0.035:
                    pair_adj -= 14.0

            total = score_a + score_b + pair_adj
            if total > best_total:
                best_total = total
                best_pair = (idx_a, sec_a, idx_b, sec_b)
                best_voc_a = voc_a
                best_voc_b = voc_b
                best_beat_b_during = beat_b_during
                best_beat_b_drop = beat_b_drop

    if best_pair is not None:
        idx_a, sec_a, idx_b, sec_b = best_pair
        mix_start = float(db_a[idx_a])
        mix_end = min(dur_a - 0.25, float(db_a[idx_a + mix_bars]))
        entry_sec = float(db_b[idx_b])
        span_a = max(mix_end - mix_start, 2.0)
        span_b = max(float(db_b[idx_b + mix_bars]) - entry_sec, 2.0)
    else:
        idx_a = max(0, len(db_a) - 5)
        mix_start = max(dur_a * 0.65, dur_a - 8.0)
        mix_end = max(mix_start + 2.0, dur_a - 0.5)
        entry_sec = min(max(0.0, float(track_b.get("mix_in_sec") or 0.0)), min(dur_b * 0.24, 38.0))
        sec_a = _section_at(mix_start, segs_a)
        sec_b = _section_at(entry_sec, segs_b)
        span_a = max(mix_end - mix_start, 2.0)
        span_b = span_a

    vol_curve, eq_style, filter_style, rev_tail, swap_center = _choose_mix_effects(
        is_beatmatch=is_beatmatch,
        c_score=c_score,
        voc_a=best_voc_a,
        voc_b=best_voc_b,
        beat_b_during=best_beat_b_during,
        beat_b_at_drop=best_beat_b_drop,
        sec_a=sec_a,
        sec_b=sec_b,
        mix_bars=mix_bars,
        energy_a=energy_a,
        energy_b=energy_b,
    )

    if not is_beatmatch:
        mix_start_f = round(mix_start, 3)
        mix_end_f = round(min(dur_a - 0.3, max(mix_start_f + 4.5, min(mix_end, mix_start_f + 10.0))), 3)
        entry_f = round(entry_sec, 3)
        return {
            "transition_type": "fade",
            "source": "allin1",
            "track_a": {
                "id": track_a["id"],
                "bpm": round(bpm_a, 4),
                "ramp_start_sec": mix_start_f,
                "mix_start_sec": mix_start_f,
                "mix_end_sec": mix_end_f,
                "section": sec_a,
            },
            "track_b": {
                "id": track_b["id"],
                "bpm": round(bpm_b, 4),
                "entry_sec": entry_f,
                "section": sec_b,
            },
            "sync": {
                "target_rate_a": 1.0,
                "initial_rate_b": 1.0,
                "ramp_duration_sec": 0.0,
            },
            "mix": {
                "duration_sec": round(mix_end_f - mix_start_f, 3),
                "bars": mix_bars,
                "volume_curve": vol_curve,
                "eq_style": eq_style,
                "filter_style": filter_style,
                "reverb_tail": rev_tail,
                "eq_swap": {
                    "bass_swap_at_progress": swap_center,
                    "bass_cut_db": -24.0,
                },
            },
        }

    # Usa sempre a razão real entre os BPMs das faixas para que a Faixa A pare exatamente no BPM da Faixa B
    chosen_ratio = nom_ratio

    if abs(chosen_ratio - 1.0) <= 0.08:
        target_rate_a = round(max(0.92, min(1.08, chosen_ratio)), 5)
        initial_rate_b = 1.0
    else:
        target_rate_a = round(max(0.92, min(1.08, chosen_ratio)), 5)
        initial_rate_b = round(max(0.93, min(1.07, target_rate_a / max(chosen_ratio, 0.5))), 5)

    bar_sec_a = 4.0 * 60.0 / bpm_a
    if abs(target_rate_a - 1.0) < 0.003:
        ramp_start = mix_start
        ramp_duration_sec = 0.0
    else:
        rate_delta = abs(target_rate_a - 1.0)
        if rate_delta < 0.020:
            ramp_bars, hold_bars = 8, 8
        elif rate_delta < 0.045:
            ramp_bars, hold_bars = 12, 12
        else:
            ramp_bars, hold_bars = 16, 16
        total_bars = ramp_bars + hold_bars
        min_ramp_t = dur_a * 0.30

        if best_pair is not None and len(db_a) > 6:
            ideal_idx = max(0, idx_a - total_bars)
            while ideal_idx < idx_a - 4 and db_a[ideal_idx] < min_ramp_t:
                ideal_idx += 1

            ideal_t = float(db_a[ideal_idx])
            snapped_idx = None
            best_snap_dist = 6.0 * bar_sec_a
            for s in segs_a:
                lbl = str(s.get("label", "")).lower()
                if lbl not in ("chorus", "verse", "inst", "bridge", "outro"):
                    continue
                st = float(s.get("start", 0.0))
                if st < min_ramp_t:
                    continue
                cand_i = _nearest_db_idx(st, db_a, 0, max(0, idx_a - 1))
                if cand_i <= idx_a - 6 and db_a[cand_i] >= min_ramp_t:
                    dist = abs(float(db_a[cand_i]) - ideal_t)
                    if dist <= best_snap_dist:
                        best_snap_dist = dist
                        snapped_idx = cand_i

            chosen_ramp_idx = snapped_idx if snapped_idx is not None else ideal_idx
            ramp_start = float(db_a[chosen_ramp_idx]) if chosen_ramp_idx <= idx_a - 4 else max(min_ramp_t, mix_start - 4.0 * bar_sec_a)
        else:
            ramp_start = max(min_ramp_t, mix_start - float(total_bars) * bar_sec_a)

        if ramp_start >= mix_start - 1.5 * bar_sec_a:
            ramp_start = max(0.0, mix_start - 4.0 * bar_sec_a)

        total_lead_sec = max(0.0, mix_start - ramp_start)
        ramp_frac = float(ramp_bars) / float(total_bars)
        if total_lead_sec >= 6.0 * bar_sec_a:
            ramp_duration_sec = round(max(4.0 * bar_sec_a, total_lead_sec * ramp_frac), 3)
        else:
            ramp_duration_sec = round(total_lead_sec, 3)

    ramp_start = round(ramp_start, 3)
    mix_start = round(mix_start, 3)
    mix_end = round(mix_end, 3)
    entry_sec = round(entry_sec, 3)
    wall_mix_dur = round(max(2.0, (mix_end - mix_start) / max(target_rate_a, 0.5)), 3)

    return {
        "transition_type": "beatmatch",
        "source": "allin1",
        "track_a": {
            "id": track_a["id"],
            "bpm": round(bpm_a, 4),
            "ramp_start_sec": ramp_start,
            "mix_start_sec": mix_start,
            "mix_end_sec": mix_end,
            "section": sec_a,
        },
        "track_b": {
            "id": track_b["id"],
            "bpm": round(bpm_b, 4),
            "entry_sec": entry_sec,
            "section": sec_b,
        },
        "sync": {
            "target_rate_a": target_rate_a,
            "initial_rate_b": initial_rate_b,
            "ramp_duration_sec": round(ramp_duration_sec, 3),
        },
        "mix": {
            "duration_sec": wall_mix_dur,
            "bars": mix_bars,
            "volume_curve": vol_curve,
            "eq_style": eq_style,
            "filter_style": filter_style,
            "reverb_tail": rev_tail,
            "eq_swap": {
                "bass_swap_at_progress": swap_center,
                "bass_cut_db": -24.0,
            },
        },
    }
