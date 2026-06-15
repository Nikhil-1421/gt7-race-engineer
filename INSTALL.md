# Install & Distribution

GT7 Race Engineer is a **self-hosted server + installable web app (PWA)**. You
run the server on a computer on the same network as your PlayStation; you open
the dashboard on your phone or tablet and "Add to Home Screen". No App Store
account, no app review, works on iOS and Android today.

---

## 0. Desktop app (easiest — no Python, no terminal)

Download the build for your computer from **GitHub Releases**
(`GT7RaceEngineer-macOS.zip` / `GT7RaceEngineer-Windows.zip`), unzip, and open
it. A status window appears and the dashboard opens in your browser. Click
**Find my PS5** and you're live — the IP is remembered for next time. The full
five-minute walkthrough is in `QUICKSTART.md`.

The builds are unsigned (no $99/yr Apple Developer ID, no Windows cert), so the
first launch needs one extra click:

- **macOS:** right-click `GT7 Race Engineer.app` → **Open** → **Open**. If
  blocked, System Settings → Privacy & Security → **Open Anyway**. Only needed
  once.
- **Windows:** SmartScreen shows "Windows protected your PC" → **More info** →
  **Run anyway**. Only needed once.

Where things live: settings persist in
`~/Library/Application Support/GT7RaceEngineer` (macOS) or
`%APPDATA%\GT7RaceEngineer` (Windows) — `config.json` plus `logs/engineer.log`
for troubleshooting. Delete the folder to factory-reset. The `GT7_IP`
environment variable still overrides the saved IP if you set it.

Building the apps yourself: `bash packaging/build_macos.sh` on a Mac or
`packaging\build_windows.bat` on Windows (PyInstaller can't cross-compile;
the GitHub Actions workflow in `.github/workflows/build-desktop.yml` builds
both on every `v*` tag). Voice extras note: the Discord path additionally
needs `ffmpeg` on the machine (`brew install ffmpeg` / `choco install ffmpeg`)
— everything else is bundled.

---

## 1. Run the server

### Option A — pip (developers)
```bash
pip install -e .            # or: pip install -r requirements.txt
gt7-engineer                # synthetic demo at http://localhost:8000
GT7_IP=192.168.1.42 gt7-engineer    # live capture from your PS5
```

### Option B — Docker (one command, no Python setup)
```bash
GT7_IP=192.168.1.42 docker compose up --build
```
`network_mode: host` is set so the container can reach GT7's UDP telemetry
(ports 33739/33740). On macOS/Windows Docker Desktop, host networking is
limited — prefer running with pip there, or run Docker on a Linux box on the LAN.

### Finding your PlayStation IP
On the console: **Settings → Network → Connection Status / View Connection
Status** → note the IP address. Your computer and PS5 must be on the same LAN.
GT7 starts broadcasting telemetry once the app sends its heartbeat — just enter
a session in-game.

### Config (env vars)
`GT7_IP` (unset → synthetic) · `PORT` (8000) · `GT7_SPEED` (synthetic accel) ·
race defaults `GT7_RACE_SECONDS`, `GT7_REFUEL_LPS`, `GT7_PIT_LOSS`. Most config
is set per-session in the ⚙ drawer instead.

---

## 2. Install on your phone (PWA)

1. On the phone, open `http://<your-computer-LAN-IP>:8000` in Safari (iOS) or
   Chrome (Android). Find the computer's IP with `ipconfig` / `ifconfig` /
   `ip addr`.
2. **iOS Safari:** Share → *Add to Home Screen*. **Android Chrome:** ⋮ →
   *Install app* / *Add to Home Screen*.
3. Launch it from the home screen — it opens full-screen (standalone), with its
   own icon, and the app shell is cached so it starts instantly. Live data
   streams over the WebSocket whenever the server is running.

This is the supported "app on your phone" experience. It is genuinely
distributable: share the repo / Docker image and anyone can self-host and
install the PWA the same way.

---

## 3. Distributing to others

- **GitHub release** of this repo + the Docker image is the primary channel.
- **PyPI**: `python -m build` then `twine upload dist/*` to publish `gt7-engineer`.
- **Docker Hub / GHCR**: `docker build -t youruser/gt7-engineer . && docker push …`.
- Users self-host (one of the options above) and install the PWA.

---

## 4. "Apple App Store" — the honest version

This codebase **cannot be shipped to the App Store as-is**, and that's a
structural fact, not a packaging gap:

- It's a **LAN server + browser client**. The phone is a thin client; without
  your computer running the server it does nothing. The App Store distributes
  self-contained native apps, not "a server you run on your PC."
- A **WKWebView wrapper** that just loads the dashboard URL is rejected under
  Apple **Guideline 4.2 (minimum functionality)** — pure web wrappers are the
  single most common rejection. It would also still require the server running,
  so it isn't standalone.

If you want a real native iOS app, it's a **separate project**, two viable paths:

1. **Native Swift client (the real one).** Reimplement the capture in Swift:
   open a UDP socket, send the `A` heartbeat to the PS5 on 33739, receive on
   33740, Salsa20-decrypt, parse the packet (the byte offsets are in
   `gt7dashboard/gt7communication.py`), and port the compute layer
   (`app/engineer.py`, `app/analysis.py`, `app/track_store.py` — all pure
   logic, straightforward to translate). Needs the **Local Network** privacy
   permission. This is how shipping GT7 telemetry apps (Sim Dashboard, Race
   Dash, etc.) work. No Python ships; the Python here becomes the reference
   implementation.
2. **Native shell + embedded server** is *not* practical on iOS (you can't run a
   long-lived Python UDP server in an iOS app sandbox). Don't go this way.

Also required for the App Store regardless of path:
- **Apple Developer Program** — ~$99/year, a Mac with Xcode, code signing.
- **IP/branding care** — "Gran Turismo 7" is Sony/Polyphony Digital's
  trademark. Existing apps frame themselves as *for* Gran Turismo and avoid
  implying endorsement; don't use Sony/PD marks or claim affiliation.
- App-review essentials: privacy policy, clear permission usage strings,
  genuine native functionality.

**Bottom line:** ship the PWA + self-host today (done). If native iOS is worth
it later, the compute layers here port directly to Swift — the work is the
UDP/decrypt client and the UI, not the strategy logic.
