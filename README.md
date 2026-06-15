# GT7 Race Engineer

A live race-engineer dashboard + post-session analysis for Gran Turismo 7
endurance racing. Double-clickable desktop app for macOS/Windows (or
self-hosted server), installable web app (PWA) on your phone. Built on the
capture layer of `gt7dashboard`, with the bokeh viz replaced by a
FastAPI + WebSocket + Canvas stack and a real strategy/analysis layer.

## Features
- **Desktop apps + zero-config connect**: download, open, click **Find my
  PS5** — auto-discovery broadcasts GT7's heartbeat and adopts whichever
  console answers, then remembers it (`QUICKSTART.md`). Manual IP entry and a
  synthetic demo mode are always available.
- **Event modes** (⚙ drawer or `POST /session`): Race · Time Trial · Test Run ·
  Reference Lap · Baseline (dev). Each declares a parameter schema; the UI
  renders the right form, the backend validates, and the dashboard shows only
  the cards that mode needs.
- **Race strategy**: fuel-to-flag, pit window, refuel litres/time at your 9 L/s
  rate, tyre deg regression, pace, alert banner ("box this lap").
- **Test Run**: stint deg + fuel-per-lap + range — the car-comparison workflow.
- **Time Trial**: live delta to a stored reference lap.
- **Baseline (dev)**: maps track length/dimensions from the position trace and
  calibrates pit-lane loss, persisted per track; race mode auto-fills pit loss.
- **Post-session analysis**: distance-aligned delta-time vs your fastest lap,
  loss-zone detection, and corner diagnosis (braking point, mid-corner speed,
  throttle-on, coasting). Live via `/analyze_last`, or offline via the CLI.
- **Discord voice engineer (VR)**: a Pycord bot speaks prioritized callouts and
  answers your voice questions in a Discord voice channel — heard through the
  PSVR2 headset via the PS5's Discord integration. Two-way, cloud TTS/STT.
  Full setup in **DISCORD_SETUP.md**.
- **Party-compatible voice (VR + PS Party)**: when your races use a PlayStation
  Party (which blocks Discord on the PS5), the engineer speaks + listens through
  a separate earpiece from your Mac or phone instead. See **PARTY_SETUP.md**.

## Architecture
1. **Capture** — `gt7dashboard.GT7Communication` (UDP, Salsa20, heartbeat, reconnect; own thread). Patched to release UDP 33740 promptly on stop, so the IP can change at runtime.
2. **Discovery** (`app/discovery.py`) — broadcasts the heartbeat (plus a /24 unicast sweep fallback) and identifies the PS5 from any reply's source address — no decrypt needed.
3. **Config** (`app/config.py`) — per-OS persisted settings (`gt7_ip`); precedence: `GT7_IP` env > config file > synthetic demo.
4. **Providers** (`app/providers.py`) — `RealProvider` / `SyntheticProvider`; both expose `telemetry`, `laps`, `lap_traces`. Swappable at runtime via `POST /config` or discovery.
5. **Adapters** (`app/adapters.py`) — captured `Lap` → `LapTrace` for baseline + analysis.
6. **Events** (`app/events.py`) — `EventType`, per-mode schemas, validated `EventConfig`.
7. **Engineer** (`app/engineer.py`) — `SessionEngineer` dispatches compute by mode.
8. **Baseline** (`app/track_store.py`) — recorder + `TrackStore` (persists `data/tracks.json`).
9. **Analysis** (`app/analysis.py`) — improvement analyzer.
10. **Server** (`app/server.py`) — 10 Hz compute loop, shared snapshot, WS fan-out at 5 Hz.
11. **Voice** (`app/callouts.py`, `voice_intent.py`, `tts.py`, `stt.py`, `discord_engineer.py`) — radio-discipline callout engine + two-way Discord voice bot.
12. **UI** (`app/static/`) — mobile PWA (manifest + service worker + icons), adaptive cards + first-run setup card.
13. **Desktop** (`app/desktop.py`, `packaging/`) — double-clickable launcher (status window, browser auto-open, file logging) packaged by PyInstaller; CI builds both OSes (`.github/workflows/build-desktop.yml`).

## Quick start
Easiest: download the desktop app from Releases and open it — see
**QUICKSTART.md**. Developer path:
```bash
pip install -e .                         # or pip install -r requirements.txt
gt7-engineer                             # synthetic demo -> http://localhost:8000
GT7_IP=192.168.1.42 gt7-engineer         # live capture from your PS5

# or Docker:
GT7_IP=192.168.1.42 docker compose up --build
```
Then open `http://<computer-LAN-IP>:8000` on your phone and **Add to Home
Screen**. Full setup, PWA install, and the native-iOS roadmap are in
**INSTALL.md**; the phased plan (store-ready Flutter app) is in **ROADMAP.md**.

## API
`GET /health` · `GET|POST /config` · `POST /discover` · `GET /schemas` ·
`GET|POST /session` · `GET /tracks` · `GET /laps` · `POST /ask` ·
`POST /analyze` · `POST /analyze_last` · `POST /baseline/pit_loss` · `WS /ws`

## Post-session CLI
```bash
python -m tools.analyze_cli my_lap.json reference_lap.json --sectors 1000 2000
```

## Distribution
Self-host (pip/Docker) + PWA is the supported path and works on iOS/Android now.
The App Store is **not** a fit for this architecture (LAN server + browser
client; Apple rejects pure web wrappers under Guideline 4.2). A real native iOS
app is a separate Swift project that reimplements the UDP capture + decrypt;
the compute layers here (`engineer`, `analysis`, `track_store`) port directly.
See INSTALL.md §4 for the full breakdown.
