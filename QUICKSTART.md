# Quickstart — racing in five minutes

The fastest path from download to a live race engineer. No Python, no terminal.

## 1. Download and open

Grab the build for your computer from the GitHub Releases page:
**GT7RaceEngineer-macOS.zip** or **GT7RaceEngineer-Windows.zip**. Unzip it.

**macOS** — first launch only: the app is unsigned, so don't double-click it
yet. Right-click `GT7 Race Engineer.app` → **Open** → **Open** in the dialog.
(If macOS says it "can't be opened", go to System Settings → Privacy &
Security and click **Open Anyway**.) After the first launch it opens normally.

**Windows** — first launch only: SmartScreen will warn about an unrecognized
app. Click **More info** → **Run anyway**. Then run `GT7RaceEngineer.exe` from
the unzipped folder normally.

A small status window appears and your browser opens the dashboard
automatically.

## 2. Connect your PlayStation

Turn on the PS5, open Gran Turismo 7 (any screen past the title works), and
make sure the console and this computer are on the same network. Then click
**Find my PS5** — in the status window or on the dashboard's setup card. The
app pings the network, finds the console, and remembers it for next time.

If discovery can't find it (some routers block broadcast between Wi-Fi and
wired), type the IP into the setup card instead. It's on the console under
**Settings → Network → Connection Status**.

## 3. Pick your session and race

Tap the ⚙ in the dashboard, choose the event type — Race, Time Trial, Test
Run, Reference Lap, or Baseline — fill in the parameters (race length, stops,
refuel rate…), and **Start session**. The dashboard goes live the moment
you're on track: fuel-to-flag, pit window, tyre degradation, pace.

## 4. On your phone (optional but great)

Open `http://<this-computer's-IP>:8000` on the phone, then **Add to Home
Screen** (Share menu on iOS Safari, ⋮ menu on Android Chrome). The status
window shows the exact address. That's the rig-mounted second screen.

## 5. Racing in VR

With the PSVR2 on you can't look at a screen, so the engineer talks to you and
listens. Two paths, both fully documented:

- **DISCORD_SETUP.md** — the engineer speaks through the PS5's own Discord
  integration into the headset, and answers questions ("Engineer, fuel check").
- **PARTY_SETUP.md** — for race nights run over a PlayStation Party: the
  engineer uses a separate earpiece instead, so it never conflicts.

Either way you can ask it anything mid-race — *"Engineer, fuel check"*,
*"when do I box"*, *"how are my tyres"* — and it answers from live telemetry.

## Where things live

Settings persist in the app's config folder (`~/Library/Application
Support/GT7RaceEngineer` on macOS, `%APPDATA%\GT7RaceEngineer` on Windows),
including logs under `logs/` if anything needs troubleshooting. Running it
without a console connected shows a synthetic demo race, so you can explore
everything before race day.
