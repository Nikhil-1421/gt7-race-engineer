# GT7 Race Engineer — Flutter app (Phase 2)

This directory is the native, on-device port of the race engineer: the same
capture layer, strategy engine, and radio callouts as the Python server, but
compiled into one app for iOS, Android, macOS, and Windows. The Python repo
one level up remains the **reference implementation** — every behavioural
question is settled by it, mechanically (see Parity below) — and stays the
desktop bridge until the Flutter desktop builds take over.

## Layout

`lib/core/` is the heart and is deliberately **pure Dart with zero package
dependencies**: `salsa20.dart` (the GT7 keystream), `packet.dart` (decrypt +
parse at the documented byte offsets), `model.dart` (frames, laps, the
integer-exact lap formatters), `events.dart` (the five modes and their
parameter schemas), `engineer.dart` (fuel-to-flag, pit window, degradation,
pace — a line-for-line port of `app/engineer.py`), `callouts.dart` (the
prioritized, debounced radio), `capture.dart` (UDP heartbeat + telemetry
socket), `discovery.dart` (find-my-PS5), and `demo.dart` (the no-console
synthetic session). `lib/app/` is the thin Flutter layer on top: `app_state.dart`
(a ChangeNotifier that owns the source, ticks the engineer at 10 Hz, and fans
callouts out to TTS), `home_screen.dart` (cards driven by `snapshot['cards']`,
exactly like the PWA), `session_sheet.dart` (the settings form, generated from
the same schema payload the server serves at `/schemas`), and
`tts_speaker.dart` (a serial speech queue so calls never talk over each
other). `tool/parity/` holds the harness and its vectors; `test/` a fast
smoke suite.

## Parity: how correctness is guaranteed

The port is not trusted to be a faithful translation — it is *checked*
against the original on every push. `tools/gen_parity_vectors.py` (repo root)
runs the **real Python reference** and serializes its behaviour into
`tool/parity/vectors/`: Salsa20 keystreams asserted against pycryptodome,
encrypted packets that round-trip through the actual `gt7dashboard` decoder,
full synthetic race / test-run / time-trial sessions replayed through the
actual engineer with every snapshot recorded, scripted callout sequences, and
the schema payload. `dart tool/parity/run_parity.dart` then replays all of it
through the Dart core and deep-compares — strings and booleans exactly,
numbers to 1e-9 — failing loudly with a diff on the first divergence.

The vectors in the repo are ground truth as of generation. If you change the
Python engine, regenerate them (`python tools/gen_parity_vectors.py` from the
repo root) and the CI workflow (`.github/workflows/flutter-ci.yml`) will hold
the Dart side to the new behaviour: it runs `flutter analyze`, the parity
harness, and `flutter test` on every push touching `flutter/`.

## Getting started

Install a current stable Flutter (3.32 or newer). The platform scaffolding
(`ios/`, `android/`, `macos/`, `windows/`) is intentionally not committed —
generate it once inside this directory and commit the result:

```bash
cd flutter
flutter create --org io.gt7raceengineer --project-name gt7_race_engineer \
  --platforms=ios,android,macos,windows .
flutter pub get
flutter run -d macos        # or: -d windows, an iPhone, an Android device
dart tool/parity/run_parity.dart   # the correctness gate, also run by CI
flutter test
```

`flutter create .` only adds the platform folders; it does not touch `lib/`,
`test/`, or `pubspec.yaml`. The app starts in demo mode with no console, so
everything is explorable immediately; tap **Find my PS5** (or enter the IP)
to go live, with GT7 open on the same network.

## Per-platform networking notes (apply after `flutter create`)

**iOS** — local-network access needs a usage string. Add to
`ios/Runner/Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds your PlayStation 5 and receives Gran Turismo 7 telemetry on your local network.</string>
```

Note that *sending UDP broadcasts* on iOS additionally requires Apple's
restricted multicast entitlement, which most apps don't have — this is why
`discovery.dart` follows the broadcast with a plain unicast sweep of the /24,
which needs no entitlement and finds the console regardless. Manual IP entry
always works.

**macOS** — the App Sandbox must allow UDP in release builds. The generated
`macos/Runner/DebugProfile.entitlements` already permits networking; add the
same two keys to `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

(The "server" entitlement is what allows binding the listening socket on
33740.)

**Android** — make sure the **main** manifest
(`android/app/src/main/AndroidManifest.xml`) declares
`<uses-permission android:name="android.permission.INTERNET"/>`; templates
sometimes carry it only in the debug/profile manifests, and release builds
then fail silently at the socket.

**Windows** — no manifest work; the first run may show the standard Windows
Defender Firewall prompt for inbound UDP. Allow it on private networks.

## Engine notes

The time-trial reference lap is entered manually in the session sheet
("1:34.500" or plain seconds) — the Python server's stored track baselines
and the post-session analyzer (`app/analysis.py`, `app/track_store.py`) are
deliberately **not** ported yet (Phase 2.1): they are batch/file-backed
features that don't gate the live race-engineer experience, and porting them
before the live loop is proven in stores would be effort ahead of evidence. A
small import bridge for the Python `tracks.json` is the natural first step
when they come over.

Spoken callouts use the device's TTS. Two-way *voice queries* ("Engineer,
fuel check") remain on the Python paths for now — `DISCORD_SETUP.md` and
`PARTY_SETUP.md` — since they're how the engineer reaches a PSVR2 headset
anyway.

One Dart subtlety, for anyone touching `core/`: number-to-string formatting
is done with integer math (`fmtMs`, `fmtClock`) precisely so the Dart VM's
`double.toString` (which renders `3.0`, where JavaScript would render `3`)
can never leak into a parity-compared string. Keep it that way.
