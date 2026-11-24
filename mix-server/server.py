import json
import threading
import time
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

import mix_engine

app = FastAPI(title="Diniz Mix Server", version="1.1")
_sync_lock = threading.Lock()
_is_scanning = False


def run_sync(full: bool = False) -> dict:
    global _is_scanning
    with _sync_lock:
        _is_scanning = True
        try:
            return mix_engine.sync_from_folder(full=full)
        finally:
            _is_scanning = False


def _periodic_worker() -> None:
    while True:
        try:
            run_sync()
        except Exception as e:
            print(f"[sync-worker] error: {e}", flush=True)
        time.sleep(60)


@app.on_event("startup")
def on_startup() -> None:
    mix_engine.init_db()
    t = threading.Thread(target=_periodic_worker, daemon=True)
    t.start()


@app.get("/api/health")
def health() -> dict:
    total_nav, analyzed = mix_engine.get_health_counts()
    return {
        "status": "ok",
        "total_navidrome": total_nav,
        "analyzed": analyzed,
        "scanning": _is_scanning,
        "analyzer": "allin1",
    }


@app.get("/api/tracks")
def tracks() -> dict:
    return {"tracks": mix_engine.list_tracks_summary()}


@app.get("/api/track/{song_id}")
def track_detail(song_id: str) -> dict:
    t = mix_engine.get_track(song_id)
    if not t:
        raise HTTPException(status_code=404, detail="track not analyzed yet")
    return {
        "id": t["id"],
        "rel_path": t["rel_path"],
        "duration": t["duration"],
        "bpm": t["bpm"],
        "camelot": t["camelot"],
        "musical_key": t["musical_key"],
        "energy": t["energy"],
        "beats": json.loads(t["beats_json"] or "[]"),
        "downbeats": json.loads(t["downbeats_json"] or "[]"),
        "segments": json.loads(t["segments_json"] or "[]"),
        "bar_beat": json.loads(t.get("bar_beat_json") or "[]"),
        "bar_vocal": json.loads(t.get("bar_vocal_json") or "[]"),
        "grid_mode": t.get("grid_mode") or "",
        "key_source": t.get("key_source") or "",
        "analysis_version": t.get("analysis_version") or 1,
        "mix_in_sec": t["mix_in_sec"],
        "mix_out_sec": t["mix_out_sec"],
        "analyzer": t["analyzer"],
    }


@app.get("/api/transition")
def transition(
    from_id: str = Query(..., alias="from"),
    to_id: str = Query(..., alias="to"),
    bars: int = Query(0, alias="bars"),
) -> dict:
    ta = mix_engine.get_track(from_id)
    tb = mix_engine.get_track(to_id)
    if not ta or not tb:
        missing = [x for x, obj in ((from_id, ta), (to_id, tb)) if not obj]
        raise HTTPException(status_code=404, detail=f"tracks not analyzed yet: {missing}")
    return mix_engine.compute_transition(ta, tb, bars_override=bars if bars in (2, 4, 8, 16) else None)


@app.post("/api/scan")
def trigger_scan() -> dict:
    # Scan manual relê todos os JSONs (o worker periódico só lê os alterados)
    stats = run_sync(full=True)
    return {"status": "ok", **stats}


@app.post("/api/ingest")
def ingest(payload: dict) -> dict:
    song_id = mix_engine.upsert_track_payload(payload, write_file=True)
    if not song_id:
        return JSONResponse(status_code=202, content={"status": "saved_unmatched", "rel_path": payload.get("rel_path", "")})
    return {"status": "ok", "song_id": song_id}
