# GT7 Race Engineer — Project Roadmap (v3, revised 2026-06-12)

## Objective

A telemetry tracker and voice race engineer for Gran Turismo 7 on PS5, usable while driving in VR (PSVR2), with information tailored to the event type (race, time trial, test run, reference lap, baseline). Launchable from macOS or Windows today, with an end state that is ready for App Store / Play Store deployment, designed for ease of use, and fully documented.

## Where the project stands

The v2 codebase (built in prior sessions) is a Python server on the `gt7dashboard` capture layer: UDP heartbeat to the PS5 on port 33739, Salsa20-decrypted telemetry received on 33740 at ~60 Hz. On top of that sit a pure-logic strategy engine (fuel-to-flag, pit-window optimizer, tire-degradation projection, pace delta), five event modes with per-mode parameter schemas driven from a settings drawer, a baseline recorder that maps track length, sectors, and pit-lane loss per track, a post-session improvement analyzer that distance-aligns laps and diagnoses where and why time is lost, and an installable PWA dashboard. The VR delivery layer is the voice engineer: a Discord bot speaks prioritized, debounced callouts into a voice channel the driver joins from the PS5, so the engineer's voice arrives in the PSVR2 headset through the PS5's own Discord mix, with two-way voice queries ("Engineer, fuel check"). A second, PlayStation-Party-compatible path speaks the same callouts from the Mac or phone into a separate earpiece. Setup is documented in README, INSTALL, DISCORD_SETUP, and PARTY_SETUP.

## Competitor pace: what GT7 telemetry allows

This was the open research question, and the answer is settled by the community that reverse-engineered the protocol: GT7's telemetry stream describes only the player's car. There is no live race position, no intervals, and no data of any kind about other cars on track, in any of the three packet formats. The "B" heartbeat (added in game update 1.42) extends the packet with five motion-platform floats (wheel rotation, sway, heave, surge, and a slip-related value), and the "~" heartbeat adds the driver's raw throttle and brake inputs — neither adds opponent data. The packet does carry grid position and car count, but only pre-race.

**Decision (2026-06-12): competitor pace is out of scope.** Because the
telemetry cannot see other cars, every route to opponent gaps requires adding
a system around the game — driver voice reports, a shared relay all league
members run, or HDMI capture with OCR. A relay prototype was built and worked,
but the integration and operational overhead (hosting, onboarding every
member, mixed-grid blind spots) outweighed the value for this project. The
product focuses on what the telemetry genuinely provides: the player's own
car, strategy, and coaching. For on-track gaps, GT7's VR HUD already shows
them natively.

## Requirement-to-architecture mapping

**Executable from macOS or Windows (near term).** Package the existing Python server as double-clickable apps with PyInstaller: `GT7 Race Engineer.app` on macOS and `GT7RaceEngineer.exe` on Windows. The launcher starts the server, auto-opens the dashboard in the default browser, and shows a small status window or tray icon. PyInstaller cannot cross-compile, so a GitHub Actions matrix (macos-latest, windows-latest) builds both artifacts per release. Documentation must cover the unsigned-binary warnings (macOS Gatekeeper right-click-open; Windows SmartScreen "run anyway") and, optionally, the signing/notarization path for clean installs.

**Ease of use.** Add PS5 auto-discovery so users never hunt for an IP address: on first run, broadcast the telemetry heartbeat across the local subnet and adopt whichever address replies, with manual entry as fallback. Combine with a first-run wizard (event mode, race parameters, voice path choice) and the existing per-mode settings drawer. Sensible defaults everywhere; the synthetic demo mode remains the zero-setup way to try the app with no console.

**App Store / Play Store readiness (end state).** The Python LAN server plus PWA architecturally cannot ship to either store — Apple rejects thin web-view wrappers under Guideline 4.2, and the phone client is non-functional without a PC running the server. The store-ready end state is therefore a native cross-platform app that performs capture on-device, which is how every shipping GT7 telemetry app works. Recommended framework: **Flutter**, for one decisive reason — a single Dart codebase targets iOS, Android, macOS, and Windows. That makes the architecture convergent: the same native app that goes to the App Store and Play Store also compiles to the macOS/Windows desktop executables, eventually retiring the PyInstaller bridge. The port consists of: the capture client in Dart (UDP socket, heartbeat cadence, Salsa20 decryption via pointycastle, packet parser using the byte offsets documented in `gt7dashboard/gt7communication.py`), a direct translation of the pure-logic compute modules (`engineer`, `analysis`, `track_store`, `events`, `callouts` — no I/O in any of them, so they port mechanically), on-device text-to-speech for the voice engineer (flutter_tts), and a native UI replicating the mode-driven dashboard. The Python codebase becomes the reference implementation and the desktop bridge until the Flutter desktop builds reach parity.

**Store submission checklist.** Apple Developer Program (about $99/year, requires a Mac with Xcode) and Google Play Console (one-time $25). iOS requires the Local Network privacy permission with a clear usage string (NSLocalNetworkUsageDescription) since the app talks to the PS5 over the LAN. A privacy policy is mandatory for both stores. Branding must avoid Sony/Polyphony Digital trademarks: name and describe the app as working *with* Gran Turismo 7 telemetry, never implying endorsement or using their marks, consistent with how existing GT7 companion apps position themselves.

## Phased plan

**Phase 1 (✅ delivered) — Desktop executables and quick wins (extends the existing Python repo).** PyInstaller specs and launcher for macOS and Windows, GitHub Actions release pipeline producing both binaries, PS5 auto-discovery, first-run wizard, runtime IP switching, and per-OS install documentation covering the Gatekeeper/SmartScreen steps. (A competitor-gap layer was built here and in a follow-up relay prototype, then removed per the descope decision above.)

**Phase 2 — Flutter native app (store-ready end state).** Dart capture client, compute-layer port with parity tests against the Python reference, native UI for all five event modes, on-device TTS callouts (the Discord and Party voice paths remain available and documented for VR), desktop builds replacing PyInstaller, then store assets, privacy policy, and submission to TestFlight / Play internal testing, graduating to production.

## Documentation set (target)

QUICKSTART (one page: download executable → wizard → race), README (architecture and features), INSTALL (per-OS desktop installs plus pip/Docker for self-hosters), DISCORD_SETUP and PARTY_SETUP (VR voice paths, existing), STORE_DEPLOYMENT (developer accounts, signing, review checklist, trademark guidance), and CONTRIBUTING (build-from-source, CI, release process).

## Immediate blockers and inputs needed

The build environment resets between sessions, so the v2 repo (`gt7-race-engineer.zip`) must be re-uploaded to extend it. Phase 2 (Flutter) starts from a clean tree and does not require it, though the zip remains valuable as the parity reference for the compute-port tests. The Path C verification (does the VR social screen show the HUD on this user's setup?) is a two-minute check to run before any future OCR work, should that ever be revisited.
