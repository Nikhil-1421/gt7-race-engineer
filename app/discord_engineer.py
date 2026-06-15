"""Discord engineer bot (Pycord).

Joins a voice channel; the driver joins the same channel from the PS5 (Discord
audio plays through the PSVR2 headset). The bot:
  - runs the CalloutEngine on the live snapshot and SPEAKS callouts (TTS)
  - LISTENS to the driver, transcribes (STT), parses intent, and answers
  - optionally mirrors callouts + a post-session report to a text channel

Runs in the same asyncio loop as the FastAPI server (launched on startup when
DISCORD_TOKEN is set). All network (Discord, OpenAI) happens on the host machine.
"""
from __future__ import annotations

import asyncio
import os
import time
import contextlib

import discord

from app.voice_intent import parse as parse_intent
from app import tts, stt


def _intents() -> discord.Intents:
    i = discord.Intents.default()
    i.message_content = True
    i.voice_states = True
    return i


class EngineerBot(discord.Bot):
    def __init__(self, state, **kw):
        super().__init__(intents=_intents(), **kw)
        self.state = state
        self._callout_last_id = 0
        self.voice: discord.VoiceClient | None = None
        self.play_q: asyncio.Queue[str] = asyncio.Queue()
        self.text_channel_id = int(os.getenv("DISCORD_TEXT_CHANNEL_ID", 0) or 0)
        self.auto_channel_id = int(os.getenv("DISCORD_VOICE_CHANNEL_ID", 0) or 0)
        self.two_way = os.getenv("ENGINEER_TWO_WAY", "1") == "1"
        self._tasks: list[asyncio.Task] = []
        self._register_commands()

    # ---- lifecycle ----------------------------------------------------
    async def on_ready(self):
        print(f"[engineer] connected as {self.user}")
        if self.auto_channel_id:
            ch = self.get_channel(self.auto_channel_id)
            if isinstance(ch, discord.VoiceChannel):
                await self._join(ch)

    async def _join(self, channel: discord.VoiceChannel):
        if self.voice and self.voice.is_connected():
            await self.voice.move_to(channel)
        else:
            self.voice = await channel.connect()
        self._start_tasks()
        await self._post_text(f"🏁 Engineer on the radio in **{channel.name}**.")

    async def _leave(self):
        for t in self._tasks:
            t.cancel()
        self._tasks.clear()
        if self.voice:
            with contextlib.suppress(Exception):
                await self.voice.disconnect()
            self.voice = None

    def _start_tasks(self):
        if self._tasks:
            return
        self._tasks = [
            asyncio.create_task(self._callout_loop()),
            asyncio.create_task(self._playback_worker()),
        ]
        if self.two_way:
            self._tasks.append(asyncio.create_task(self._listen_loop()))

    # ---- speaking -----------------------------------------------------
    async def _callout_loop(self):
        while True:
            for c in [c for c in self.state.callout_log if c["id"] > self._callout_last_id]:
                self._callout_last_id = c["id"]
                await self.play_q.put(c["text"])
                await self._post_text(f"📻 {c['text']}")
            await asyncio.sleep(0.5)

    async def _playback_worker(self):
        while True:
            text = await self.play_q.get()
            if not (self.voice and self.voice.is_connected()):
                continue
            try:
                path = await tts.synthesize(text)
                while self.voice.is_playing():
                    await asyncio.sleep(0.1)
                self.voice.play(discord.FFmpegPCMAudio(path))
                while self.voice.is_playing():
                    await asyncio.sleep(0.1)
                with contextlib.suppress(OSError):
                    os.remove(path)
            except Exception as e:
                print(f"[engineer] tts/play error: {e}")

    async def speak(self, text: str):
        await self.play_q.put(text)

    # ---- listening (two-way) -----------------------------------------
    async def _listen_loop(self):
        window = float(os.getenv("ENGINEER_LISTEN_WINDOW", 4.0))
        while True:
            if not (self.voice and self.voice.is_connected()):
                await asyncio.sleep(1.0)
                continue
            try:
                sink = await self._record_window(window)
                await self._process_sink(sink)
            except Exception as e:
                print(f"[engineer] listen error: {e}")
                await asyncio.sleep(1.0)

    async def _record_window(self, seconds: float):
        sink = discord.sinks.WaveSink()
        done = asyncio.Event()
        holder = {}

        async def _cb(s, *a):
            holder["sink"] = s
            done.set()

        self.voice.start_recording(sink, _cb)
        await asyncio.sleep(seconds)
        with contextlib.suppress(Exception):
            self.voice.stop_recording()
        await done.wait()
        return holder.get("sink", sink)

    async def _process_sink(self, sink):
        import tempfile
        for user_id, audio in getattr(sink, "audio_data", {}).items():
            if user_id == self.user.id:
                continue
            fd, path = tempfile.mkstemp(suffix=".wav", prefix="eng_in_")
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(audio.file.read())
                text = await stt.transcribe(path)
                if not text:
                    continue
                ans = parse_intent(text, self.state.snapshot)
                if ans:
                    await self._post_text(f"🎙️ *{text}* → {ans}")
                    await self.speak(ans)
            finally:
                with contextlib.suppress(OSError):
                    os.remove(path)

    # ---- text channel -------------------------------------------------
    async def _post_text(self, msg: str):
        if not self.text_channel_id:
            return
        ch = self.get_channel(self.text_channel_id)
        if ch:
            with contextlib.suppress(Exception):
                await ch.send(msg)

    # ---- slash commands ----------------------------------------------
    def _register_commands(self):
        @self.slash_command(description="Bring the engineer into your voice channel")
        async def join(ctx: discord.ApplicationContext):
            if ctx.author.voice and ctx.author.voice.channel:
                await self._join(ctx.author.voice.channel)
                await ctx.respond("Engineer joining.", ephemeral=True)
            else:
                await ctx.respond("Join a voice channel first.", ephemeral=True)

        @self.slash_command(description="Dismiss the engineer")
        async def leave(ctx: discord.ApplicationContext):
            await self._leave()
            await ctx.respond("Engineer out.", ephemeral=True)

        @self.slash_command(description="Spoken status check")
        async def status(ctx: discord.ApplicationContext):
            from app.voice_intent import answer
            await self.speak(answer("status", self.state.snapshot))
            await ctx.respond("On the radio.", ephemeral=True)


async def start_bot(state):
    token = os.getenv("DISCORD_TOKEN")
    if not token:
        print("[engineer] DISCORD_TOKEN not set — Discord engineer disabled.")
        return None
    bot = EngineerBot(state)
    asyncio.create_task(bot.start(token))
    return bot
