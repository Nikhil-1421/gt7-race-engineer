"""Local voice output — speaks callouts on the host machine.

Party-compatible: the engineer audio comes out of the Mac (to a Bluetooth
bone-conduction earpiece paired with the Mac), never touching the PS5's chat
slot, so it coexists with a PlayStation Party.

Speakers (auto-detected, override with ENGINEER_TTS):
  - "premium": cloud TTS (app.tts) -> play with `afplay` (macOS)   [needs OPENAI_API_KEY]
  - "say":     macOS built-in `say` command                        [zero setup]
The speaker is injectable so the selection/dedup logic is testable headless.
"""
from __future__ import annotations

import asyncio
import os
import shutil
from typing import Awaitable, Callable


async def _say_speaker(text: str) -> None:
    proc = await asyncio.create_subprocess_exec(
        "say", "-v", os.getenv("ENGINEER_SAY_VOICE", "Daniel"), text)
    await proc.wait()


async def _premium_speaker(text: str) -> None:
    from app import tts
    path = await tts.synthesize(text)
    try:
        proc = await asyncio.create_subprocess_exec("afplay", path)
        await proc.wait()
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def default_speaker() -> Callable[[str], Awaitable[None]]:
    pref = os.getenv("ENGINEER_TTS", "auto").lower()
    has_key = bool(os.getenv("OPENAI_API_KEY"))
    if pref == "premium" or (pref == "auto" and has_key and shutil.which("afplay")):
        return _premium_speaker
    return _say_speaker


class LocalVoice:
    """Polls the shared callout log and speaks new lines on the host."""

    def __init__(self, state, speaker: Callable[[str], Awaitable[None]] | None = None):
        self.state = state
        self.speaker = speaker or default_speaker()
        self._last_id = 0

    async def run(self):
        while True:
            try:
                new = [c for c in self.state.callout_log if c["id"] > self._last_id]
                for c in new:
                    self._last_id = c["id"]
                    await self.speaker(c["text"])      # serial: no overlap
            except Exception as e:
                print(f"[local-voice] {e}")
            await asyncio.sleep(0.3)


async def start_local_voice(state):
    if os.getenv("ENGINEER_LOCAL_VOICE", "0") != "1":
        return None
    lv = LocalVoice(state)
    asyncio.create_task(lv.run())
    print("[local-voice] speaking callouts on this machine "
          f"({'premium' if lv.speaker is _premium_speaker else 'say'}).")
    return lv
