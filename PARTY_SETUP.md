# Party-Compatible Setup (macOS) — engineer through a separate earpiece

Use this when your races run in a **PlayStation Party**. The PS5 only allows one
chat-audio channel at a time — Party *or* Discord, never both — so the Discord
bot can't share the PS5 during a Party race. Instead, the engineer talks (and
listens) through a **separate earpiece** that never touches the PS5's audio, so
it coexists with the Party.

What you'll hear: **game + your league Party through the PSVR2 headset**, and the
**engineer in a separate ear**. A bone-conduction earpiece is ideal — it leaves
your ear canals open so the PSVR2 audio isn't blocked.

There are two output options. Most people want **A** (rock-solid). **B** is more
portable. You can also combine: A for callouts, B's button for questions.

---

## Option A — Engineer speaks from your Mac (recommended)

The Mac speaks the callouts to a Bluetooth earpiece paired with the **Mac**.
No browser, no iOS quirks, premium voice available.

1. Do the base install (Parts 1–2 of `DISCORD_SETUP.md`: Homebrew, Python,
   ffmpeg, venv, `pip install -r requirements.txt`). You do **not** need the
   Discord bot for this path.
2. **Pair your Bluetooth bone-conduction earpiece to the Mac** (System Settings →
   Bluetooth) and set it as the Mac's output (Sound → Output), or use
   `SwitchAudioSource`. Test with `say "radio check"` in Terminal — you should
   hear it in the earpiece.
3. In your `.env` set:
   ```
   GT7_IP=192.168.1.42
   ENGINEER_LOCAL_VOICE=1
   ENGINEER_TTS=premium        # premium cloud voice (needs OPENAI_API_KEY); or "say" for built-in
   OPENAI_API_KEY=sk-...        # only needed for premium
   ```
4. Run it:
   ```bash
   source .venv/bin/activate
   python -m app.server
   ```
   You'll see `[local-voice] speaking callouts on this machine`. Put on the
   headset, join your Party as normal, and you'll get callouts in the earpiece.

---

## Option B — Engineer speaks from your phone (portable)

The phone PWA speaks callouts to a Bluetooth earpiece paired with the **phone**.

1. Run the server on the Mac (`python -m app.server`, with `GT7_IP` set).
2. On the phone, open `http://<mac-LAN-IP>:8000` and Add to Home Screen
   (`INSTALL.md` §2).
3. Pair your earpiece to the **phone**.
4. In the dashboard, tap **🔊 Engineer: off → on**. That tap is required (it
   unlocks audio on iOS) — you'll hear "Radio check." Choose **Device voice**
   (free, on-device) or **Premium voice** (cloud, needs `OPENAI_API_KEY`).
5. Prop the phone on the rig with the screen on, put on the headset, join your
   Party. Callouts play in the earpiece.

> iOS note: Safari may suspend audio if the PWA is fully backgrounded with the
> screen off. Keep it foreground (screen on) on the rig. Option A avoids this
> entirely.

---

## Two-way (asking questions) on the party path

- **From the phone:** hold **🎙 Hold to ask**, say your question ("fuel check",
  "when do I box", "how are my tyres"), release. It answers in your earpiece.
- **Secure-context catch:** browsers only allow the mic over **HTTPS or
  localhost**. Over a plain `http://<LAN-IP>` address, iOS Safari will block the
  mic, so the **Hold to ask** button needs the server served over HTTPS to work
  on the phone. Quick options: run a local HTTPS reverse proxy (e.g. `caddy` or
  `mkcert` + a tiny TLS front), or use the phone path for **callouts only** and
  ask questions another way. Callouts (speaking) work fine over plain http.
- **Discord two-way still exists** for any session that is *not* on a Party
  (single-player practice, lobbies without Party voice): there the bot's
  cloud-STT mic path works through the PS5. See `DISCORD_SETUP.md`.

---

## Recommended party-day combo
- **Callouts:** Option A (Mac → earpiece) — set and forget, premium voice.
- **Questions (optional):** the phone's Hold-to-ask, if you set up HTTPS;
  otherwise run callouts-only and you'll still get every fuel/pit/deg call.
- **Critical alerts you can't miss:** consider a haptic buzz too (a future
  add) — it's audio-agnostic and works regardless of Party/Discord.

The engineer's brain (callout cadence + answers) is identical across every
path — only the "mouth" changes — so you can switch between Discord (non-Party)
and the earpiece (Party) per session with no other changes.
