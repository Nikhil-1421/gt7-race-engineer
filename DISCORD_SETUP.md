# Discord Voice Engineer — Full Setup (macOS)

This walks you from nothing to a talking, listening race engineer you hear
through your PSVR2 headset. ~20–30 minutes the first time. Five parts:

1. Install prerequisites on your Mac
2. Get and run the program
3. Create the Discord bot
4. Get an OpenAI key + configure
5. Set it up on the PlayStation and race

---

## Part 1 — Prerequisites (macOS)

1. **Open Terminal** (Cmd-Space, type "Terminal", Enter).
2. **Install Homebrew** (skip if you have it):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   Follow the prompts; when it finishes, run the two `echo … >> ~/.zprofile` /
   `eval` lines it prints so `brew` is on your PATH.
3. **Install Python, ffmpeg, git:**
   ```bash
   brew install python@3.12 ffmpeg git
   ```
   `ffmpeg` is required — it's what plays the engineer's voice into Discord.
4. Verify:
   ```bash
   python3 --version   # 3.10+ 
   ffmpeg -version      # prints version info
   ```

---

## Part 2 — Get and run the program

1. **Unzip** `gt7-race-engineer.zip` (or `git clone` your repo). In Terminal, go
   into the folder:
   ```bash
   cd ~/Downloads/race-engineer        # adjust to where you put it
   ```
2. **Create a virtual environment and install:**
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```
   (Leave this Terminal open; the `.venv` stays active. Next time, just
   `cd` back in and run `source .venv/bin/activate` again.)
3. **Smoke test — synthetic demo, no console needed:**
   ```bash
   python -m app.server
   ```
   Open `http://localhost:8000` in a browser — you should see the dashboard
   running a simulated race. Press Ctrl-C to stop. If that works, the core is
   good and we just need to add Discord + OpenAI + your PS5.

---

## Part 3 — Create the Discord bot

You need a Discord **server** you control (free: in the app, click the "+" on
the left rail → Create My Own). Then:

1. Go to **https://discord.com/developers/applications** → **New Application**,
   name it "Race Engineer", create.
2. Left sidebar → **Bot** → **Reset Token** → **Copy**. This is your
   `DISCORD_TOKEN`. Keep it secret. (You'll paste it in Part 4.)
3. On the same Bot page, enable these under **Privileged Gateway Intents**:
   - **Server Members Intent**
   - **Message Content Intent**
   (Voice doesn't need a privileged intent, but these let slash commands and
   text logging work.)
4. Left sidebar → **OAuth2** → **URL Generator**:
   - Scopes: check **bot** and **applications.commands**
   - Bot Permissions: **View Channels**, **Connect**, **Speak**,
     **Use Voice Activity**, and (for text logging) **Send Messages**
   - Copy the generated URL at the bottom, open it in your browser, and
     **authorize the bot into your server**.
5. In Discord, create a **voice channel** (e.g. "Pit Wall") and, if you want the
   text log, a **text channel** (e.g. "engineer-log").
6. **Get the channel IDs** (optional but recommended for auto-join): Discord →
   User Settings → Advanced → enable **Developer Mode**. Then right-click your
   voice channel → **Copy Channel ID** (and the text channel too).

---

## Part 4 — OpenAI key + configuration

The OpenAI key powers both the **voice** (text-to-speech) and the **listening**
(speech-to-text), so one key does everything.

1. Go to **https://platform.openai.com/api-keys** → **Create new secret key** →
   copy it (starts with `sk-`). You'll need billing set up; usage for this is
   small (TTS + Whisper are cheap per request).
2. In the project folder, **create your `.env`** from the template:
   ```bash
   cp .env.example .env
   open -e .env        # opens in TextEdit
   ```
3. Fill it in and save:
   ```
   GT7_IP=192.168.1.42                 # your PS5 IP (Part 5, step 1)
   DISCORD_TOKEN=(paste from Part 3.2)
   DISCORD_VOICE_CHANNEL_ID=(Pit Wall channel ID)   # optional auto-join
   DISCORD_TEXT_CHANNEL_ID=(engineer-log channel ID)# optional
   OPENAI_API_KEY=sk-...
   TTS_VOICE=onyx                      # try: onyx, ash, sage, echo
   ENGINEER_TWO_WAY=1
   ```
   (Optional premium voice: set `TTS_PROVIDER=elevenlabs`,
   `ELEVENLABS_API_KEY`, and `ELEVENLABS_VOICE_ID` instead.)

---

## Part 5 — PlayStation setup and racing

1. **Find your PS5's IP:** PS5 → Settings → Network → View Connection Status →
   note the IP address. Put it in `.env` as `GT7_IP`. (Your Mac and PS5 must be
   on the same network.)
2. **Link Discord to your PSN account:** PS5 → Settings → Users and Accounts →
   Linked Services → **Discord** → link, and sign in.
3. **Join the voice channel from the PS5:** PS button → **Game Base** →
   **Discord** tab → pick your server → join the **Pit Wall** voice channel.
   (You can also start the call on your phone's Discord and use **Transfer to
   PlayStation**.)
4. **Start the engineer on your Mac:**
   ```bash
   source .venv/bin/activate     # if not already active
   python -m app.server
   ```
   The bot logs `connected as Race Engineer` and joins the Pit Wall channel
   (auto, if you set `DISCORD_VOICE_CHANNEL_ID`; otherwise type **/join** in the
   server from your phone/PC while you're in the channel). You'll hear
   "Radio check — engineer here."
5. **Balance the audio on PS5:** PS button → **Sound** card → set **Chat Audio
   vs Game Audio** so the engineer sits under the game (start ~30% chat). With
   PSVR2 on, this mix plays through the headset earbuds.
6. **Put the headset on and race.** You'll get fuel-to-flag updates, "box this
   lap," tyre-deg warnings, and "two to go" automatically.
7. **Ask it things** (two-way): say the wake word then your question —
   *"Engineer, fuel check"* · *"Engineer, when do I box?"* · *"Engineer, how are
   my tyres?"* · *"Engineer, status."* It transcribes, answers in voice, and (if
   set) logs the exchange to the text channel.

---

## Using it / commands
- **Slash commands** (type in your Discord server from phone/PC): `/join`,
  `/leave`, `/status`.
- **Voice queries:** start with "Engineer…". Recognised topics: fuel, pit/box,
  tyres, pace, time/laps, deg, status.

## Troubleshooting
- **No engineer audio in the headset:** check the PS5 Sound card chat/game
  balance isn't at 0% chat; confirm you actually joined the *voice* channel; on
  the Mac confirm `ffmpeg -version` works and the terminal shows no `tts/play
  error`.
- **Bot won't join / "disabled":** `DISCORD_TOKEN` missing or wrong in `.env`,
  or the bot wasn't invited (Part 3.4).
- **Voice questions ignored:** PS5 has **no Discord noise suppression**, so
  engine noise hurts recognition — speak the wake word clearly, keep questions
  short, and check the text channel to see what it transcribed. Raise mic level
  in PS5 → Settings → Sound → Microphone.
- **No live telemetry (synthetic-looking data):** wrong `GT7_IP`, Mac/PS5 on
  different networks, or you're not in a session in-game yet. The dashboard's
  top pill shows `live · racing` when telemetry is flowing.
- **PSVR2 audio:** the Discord mix follows the PS5's active audio output. If you
  ever don't hear chat in the headset, confirm the headset is the selected
  output and re-check the chat/game balance.

## Cost note
OpenAI TTS + Whisper are billed per use and are inexpensive for this (short
lines, occasional questions), but they are not free — keep an eye on your
OpenAI usage dashboard. The PWA/dashboard and telemetry remain free and local.
