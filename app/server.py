"""FastAPI server — event-aware, with session switching and post-session analysis.

Endpoints:
  GET  /              -> dashboard page
  GET  /schemas       -> per-event-type parameter schemas (UI renders config forms)
  GET  /session       -> current event type + values
  POST /session       -> set event type + values  {type, values}
  GET  /tracks        -> stored track baselines (name, length, pit_loss)
  POST /analyze       -> post-session improvement report  {target, reference, sectors?}
  WS   /ws            -> live snapshot stream

Run synthetic:   python -m app.server
Run live:        GT7_IP=192.168.1.42 python -m app.server
"""
from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path

try:                                  # optional: load a .env file if present
    from dotenv import load_dotenv
    load_dotenv()
except Exception:
    pass

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles

from app.events import EventConfig, EventType, schemas_payload
from app.engineer import SessionEngineer
from app.providers import SyntheticProvider, RealProvider
from app.track_store import TrackStore, BaselineRecorder, TrackBaseline
from app.analysis import LapTrace, analyze, format_report
from app.callouts import CalloutEngine
from app.voice_intent import parse as parse_intent
from app import config as user_config

STATIC_DIR = Path(__file__).parent / "static"


class AppState:
    def __init__(self):
        self.tracks = TrackStore()
        self.speed = float(os.getenv("GT7_SPEED", 1.0))

        ip = user_config.get_gt7_ip()          # env GT7_IP > config file > ''
        if ip:
            self.provider = RealProvider(ip)
            self.mode = f"PS5 @ {ip}"
            self._synthetic = False
        else:
            self.provider = SyntheticProvider()
            self.mode = "SYNTHETIC"
            self._synthetic = True
        self.gt7_ip = ip

        # default event = race with the v1 defaults
        self.event = EventConfig.build(
            EventType.RACE,
            race_minutes=int(os.getenv("GT7_RACE_SECONDS", 2400)) // 60,
            refuel_rate_lps=float(os.getenv("GT7_REFUEL_LPS", 9.0)),
            pit_lane_loss_s=float(os.getenv("GT7_PIT_LOSS", 22.0)),
        )
        self.clock = 0.0
        self.snapshot = {"connected": False, "in_race": False}
        self._baseline_seen = 0
        self.callout_engine = CalloutEngine()
        self.callout_log: list[dict] = []
        self._callout_seq = 0
        self._build_engineer()

    def maybe_record_baseline(self):
        """In BASELINE/REFERENCE mode, build & store a baseline from each new lap."""
        if self.event.type not in (EventType.BASELINE, EventType.REFERENCE_LAP):
            return
        traces = getattr(self.provider, "lap_traces", [])
        if len(traces) <= self._baseline_seen:
            return
        self._baseline_seen = len(traces)
        tr = traces[-1]
        name = self.event.get("track_name", "") or "Unknown"
        rec = BaselineRecorder(name)
        for x, z, s in zip(tr.x, tr.z, tr.speed):
            rec.add_sample(x, z, s)
        lap_ms = self.provider.laps[-1].lap_finish_time_ms if self.provider.laps else 0
        try:
            bl = rec.finalize(lap_ms=lap_ms)
        except ValueError:
            return
        existing = self.tracks.get(name)
        if existing:
            if existing.pit_loss_s is not None:
                bl.pit_loss_s = existing.pit_loss_s
            # only overwrite geometry if this lap is faster (cleaner reference)
            if existing.best_lap_ms > 0 and lap_ms > 0 and existing.best_lap_ms <= lap_ms:
                return
        self.tracks.put(bl)

    def _build_engineer(self):
        ev = self.event
        # auto-fill pit loss from a stored baseline for the chosen track (race mode)
        if ev.type == EventType.RACE:
            tname = ev.get("track_name", "")
            bl = self.tracks.get(tname) if tname else None
            if bl and bl.pit_loss_s and abs(float(ev.get("pit_lane_loss_s", 22.0)) - 22.0) < 1e-6:
                ev.values["pit_lane_loss_s"] = bl.pit_loss_s
        # reference for time-trial delta
        ref_name = ev.get("reference_track", "") or ev.get("track_name", "")
        reference = self.tracks.get(ref_name) if ref_name else None
        self.engineer = SessionEngineer(ev, reference=reference)
        if self._synthetic and hasattr(self.provider, "add_pit_listener"):
            self.provider.add_pit_listener(self.engineer.notify_pit)

    def set_event(self, type_: str, values: dict):
        self.event = EventConfig.build(type_, **(values or {}))
        # fresh sim for a new synthetic session
        if self._synthetic:
            self.provider = SyntheticProvider()
            self.clock = 0.0
        self.callout_engine = CalloutEngine()
        self.callout_log = []
        self._build_engineer()

    def set_gt7_ip(self, ip: str, persist: bool = True) -> None:
        """Switch capture source at runtime: '' -> synthetic, else live PS5."""
        ip = (ip or "").strip()
        old = self.provider
        if hasattr(old, "stop"):
            old.stop()
        if ip:
            self.provider = RealProvider(ip)
            self.mode = f"PS5 @ {ip}"
            self._synthetic = False
        else:
            self.provider = SyntheticProvider()
            self.mode = "SYNTHETIC"
            self._synthetic = True
            self.clock = 0.0
        self.gt7_ip = ip
        self._baseline_seen = 0
        if persist and not os.getenv("GT7_IP"):     # env override stays authoritative
            user_config.save({"gt7_ip": ip})
        self._build_engineer()


state = AppState()
app = FastAPI(title="GT7 Race Engineer")


async def compute_loop():
    last = time.monotonic()
    while True:
        now = time.monotonic()
        dt = now - last
        last = now
        sim_dt = dt * state.speed
        state.clock += sim_dt
        state.provider.step(sim_dt)
        state.maybe_record_baseline()
        snap = state.engineer.snapshot(state.provider.telemetry, state.provider.laps, now=state.clock)
        snap["mode"] = state.mode
        snap["gt7_ip"] = state.gt7_ip
        snap["synthetic"] = state._synthetic
        # central callouts — every output (phone, Mac, Discord) consumes these
        for c in state.callout_engine.ingest(snap, state.clock):
            state._callout_seq += 1
            state.callout_log.append({"id": state._callout_seq, "text": c.text,
                                      "priority": c.priority, "category": c.category})
        state.callout_log = state.callout_log[-50:]
        snap["callouts"] = state.callout_log[-8:]
        state.snapshot = snap
        await asyncio.sleep(0.1)


@app.on_event("startup")
async def _startup():
    asyncio.create_task(compute_loop())
    from app.local_voice import start_local_voice
    await start_local_voice(state)
    if os.getenv("DISCORD_TOKEN"):
        try:
            from app.discord_engineer import start_bot
            state.discord_bot = await start_bot(state)
        except Exception as e:
            print(f"[engineer] Discord bot disabled: {e}")


@app.get("/", response_class=HTMLResponse)
async def index():
    return (STATIC_DIR / "index.html").read_text()


@app.get("/manifest.webmanifest")
async def manifest():
    return PlainTextResponse((STATIC_DIR / "manifest.webmanifest").read_text(),
                             media_type="application/manifest+json")


@app.get("/sw.js")
async def service_worker():
    return PlainTextResponse((STATIC_DIR / "sw.js").read_text(),
                             media_type="application/javascript",
                             headers={"Service-Worker-Allowed": "/"})


@app.get("/schemas")
async def schemas():
    return JSONResponse(schemas_payload())


@app.get("/catalog")
async def catalog():
    """Track + car catalog for the cascading session selectors."""
    from app.catalog import load_catalog
    return JSONResponse(load_catalog())


@app.get("/session")
async def get_session():
    return JSONResponse(state.event.to_dict())


@app.post("/session")
async def set_session(req: Request):
    body = await req.json()
    state.set_event(body.get("type", "race"), body.get("values", {}))
    return JSONResponse({"ok": True, "event": state.event.to_dict()})


@app.get("/tracks")
async def tracks():
    return JSONResponse([
        {"name": n, "length_m": (b.length_m if (b := state.tracks.get(n)) else 0),
         "pit_loss_s": b.pit_loss_s, "best_lap_ms": b.best_lap_ms}
        for n in state.tracks.names()
    ])


@app.get("/references")
async def references():
    """Saved reference laps — powers the Load dropdown and time-trial picker."""
    from app.model import fmt_ms
    out = []
    for name in state.tracks.names():
        bl = state.tracks.get(name)
        if not bl:
            continue
        out.append({
            "name": bl.name,
            "best_lap_ms": bl.best_lap_ms,
            "best_lap_str": fmt_ms(bl.best_lap_ms) if bl.best_lap_ms and bl.best_lap_ms > 0 else None,
            "length_m": bl.length_m,
            "pit_loss_s": bl.pit_loss_s,
            "has_line": bool(bl.reference_line),
        })
    return JSONResponse({"references": out})


@app.post("/reference/save_last")
async def save_reference_last(req: Request):
    """Explicitly save the last completed lap as a track's reference. Works in
    any mode, with no faster-only gate. Body: {track_name?} (defaults to the
    current session's track)."""
    raw = await req.body()
    body = {}
    if raw:
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
    name = (body.get("track_name") or state.event.get("track_name", "") or "").strip()
    if not name:
        return JSONResponse({"ok": False, "error": "no track selected"}, status_code=400)
    traces = getattr(state.provider, "lap_traces", [])
    if not traces:
        return JSONResponse({"ok": False, "error": "no completed laps yet"}, status_code=400)
    tr = traces[-1]
    rec = BaselineRecorder(name)
    for x, z, s in zip(tr.x, tr.z, tr.speed):
        rec.add_sample(x, z, s)
    lap_ms = state.provider.laps[-1].lap_finish_time_ms if state.provider.laps else 0
    try:
        bl = rec.finalize(lap_ms=lap_ms)
    except ValueError as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=400)
    existing = state.tracks.get(name)
    if existing and existing.pit_loss_s is not None:
        bl.pit_loss_s = existing.pit_loss_s
    state.tracks.put(bl)
    from app.model import fmt_ms
    return JSONResponse({"ok": True, "name": bl.name, "best_lap_ms": bl.best_lap_ms,
                         "best_lap_str": fmt_ms(bl.best_lap_ms) if bl.best_lap_ms > 0 else None,
                         "length_m": bl.length_m, "stored_at": str(state.tracks.path)})


@app.post("/analyze")
async def analyze_ep(req: Request):
    body = await req.json()
    def trace(d, label):
        return LapTrace(d["x"], d["z"], d["speed"], d["throttle"], d["brake"], d["t_ms"], label)
    rep = analyze(trace(body["target"], "target"),
                  trace(body["reference"], "reference"),
                  sector_bounds_m=body.get("sectors"))
    rep["report_text"] = format_report(rep)
    return JSONResponse(rep)


@app.get("/laps")
async def laps_list():
    return JSONResponse([
        {"index": i, "number": l.number, "time_ms": l.lap_finish_time_ms, "outlier": l.is_outlier}
        for i, l in enumerate(state.provider.laps)
    ])


@app.post("/analyze_last")
async def analyze_last(req: Request):
    try:
        body = await req.json()
    except Exception:
        body = {}
    traces = getattr(state.provider, "lap_traces", [])
    laps = state.provider.laps
    if len(traces) < 2:
        return JSONResponse({"error": "need at least 2 completed laps"}, status_code=400)

    target_i = int(body.get("target_index", len(traces) - 1))
    if "reference_index" in body:
        ref_i = int(body["reference_index"])
    else:
        cand = [(laps[i].lap_finish_time_ms, i) for i in range(min(len(laps), len(traces)))
                if not laps[i].is_outlier and laps[i].lap_finish_time_ms > 0 and i != target_i]
        ref_i = min(cand)[1] if cand else 0

    sectors = None
    bl = state.tracks.get(state.event.get("track_name", "") or state.event.get("reference_track", ""))
    if bl:
        sectors = bl.sector_distances_m
    rep = analyze(traces[target_i], traces[ref_i], sector_bounds_m=sectors)
    rep["report_text"] = format_report(rep)
    rep["target_index"], rep["reference_index"] = target_i, ref_i
    return JSONResponse(rep)


@app.post("/baseline/pit_loss")
async def set_pit_loss(req: Request):
    b = await req.json()
    loss = BaselineRecorder.measure_pit_loss(int(b["normal_lap_ms"]), int(b["pit_lap_ms"]),
                                             float(b.get("refuel_s", 0.0)))
    name = b["track_name"]
    bl = state.tracks.get(name) or TrackBaseline(name=name)
    bl.pit_loss_s = loss
    state.tracks.put(bl)
    return JSONResponse({"ok": True, "track": name, "pit_loss_s": loss})


@app.post("/ask")
async def ask(req: Request):
    """Driver voice question (already transcribed by the phone) -> spoken answer."""
    body = await req.json()
    answer = parse_intent(body.get("text", ""), state.snapshot)
    return JSONResponse({"answer": answer})


@app.get("/health")
async def health():
    return JSONResponse({"ok": True, "mode": state.mode,
                         "connected": bool(state.snapshot.get("connected"))})


@app.get("/config")
async def get_config():
    return JSONResponse({"gt7_ip": state.gt7_ip, "synthetic": state._synthetic,
                         "env_override": bool(os.getenv("GT7_IP")),
                         "config_path": str(user_config.config_path())})


@app.post("/config")
async def set_config(req: Request):
    body = await req.json()
    if "gt7_ip" in body:
        state.set_gt7_ip(body.get("gt7_ip") or "")
    return JSONResponse({"ok": True, "gt7_ip": state.gt7_ip, "mode": state.mode})


@app.post("/discover")
async def discover_ps5(req: Request):
    """Find the PS5 automatically. Stops live capture during the scan so
    UDP 33740 is free, then adopts the found console (or restores)."""
    from app.discovery import discover
    try:
        body = await req.json()
    except Exception:
        body = {}
    previous = state.gt7_ip
    if not state._synthetic:
        state.set_gt7_ip("", persist=False)        # release the port
        await asyncio.sleep(0.3)
    res = await asyncio.to_thread(
        discover,
        float(body.get("timeout_s", 6.0)),
        bool(body.get("sweep", True)),
        body.get("extra_targets"),
    )
    if res.ip:
        state.set_gt7_ip(res.ip)
        return JSONResponse({"ok": True, "ip": res.ip, "elapsed_s": res.elapsed_s})
    if previous:                                   # nothing found -> restore
        state.set_gt7_ip(previous, persist=False)
    return JSONResponse({"ok": False, "error": res.error,
                         "tried_sweep": res.tried_sweep}, status_code=404)


@app.get("/tts")
async def tts_audio(text: str):
    """Premium cloud voice for the phone path: returns mp3 to play in the browser."""
    from fastapi.responses import Response
    try:
        from app import tts as tts_mod
        path = await tts_mod.synthesize(text)
        data = Path(path).read_bytes()
        Path(path).unlink(missing_ok=True)
        return Response(content=data, media_type="audio/mpeg")
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=503)


@app.websocket("/ws")
async def ws(sock: WebSocket):
    await sock.accept()
    try:
        while True:
            await sock.send_text(json.dumps(state.snapshot))
            await asyncio.sleep(0.2)
    except (WebSocketDisconnect, Exception):
        return


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

def main():
    import uvicorn
    uvicorn.run(app, host=os.getenv("HOST", "0.0.0.0"), port=int(os.getenv("PORT", 8000)))


if __name__ == "__main__":
    main()