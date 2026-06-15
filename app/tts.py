"""Cloud text-to-speech for the engineer's voice.

Pluggable provider via env:
  TTS_PROVIDER = openai (default) | elevenlabs
  OPENAI_API_KEY            + TTS_VOICE      (default "onyx")
  ELEVENLABS_API_KEY        + ELEVENLABS_VOICE_ID

synthesize(text) -> path to a temp .mp3 that Discord's FFmpegPCMAudio can play.
Network calls are async (httpx). The request-building is split out so provider
routing can be unit-tested without hitting the network.
"""
from __future__ import annotations

import os
import tempfile

import httpx


def build_request(text: str, provider: str | None = None) -> dict:
    """Return {url, headers, json|data} for the chosen provider (no network)."""
    provider = (provider or os.getenv("TTS_PROVIDER", "openai")).lower()
    if provider == "elevenlabs":
        voice = os.getenv("ELEVENLABS_VOICE_ID", "")
        return {
            "url": f"https://api.elevenlabs.io/v1/text-to-speech/{voice}",
            "headers": {"xi-api-key": os.getenv("ELEVENLABS_API_KEY", ""),
                        "Content-Type": "application/json"},
            "json": {"text": text, "model_id": os.getenv("ELEVENLABS_MODEL", "eleven_turbo_v2_5")},
            "provider": "elevenlabs",
        }
    # default: OpenAI
    return {
        "url": "https://api.openai.com/v1/audio/speech",
        "headers": {"Authorization": f"Bearer {os.getenv('OPENAI_API_KEY', '')}"},
        "json": {"model": os.getenv("TTS_MODEL", "gpt-4o-mini-tts"),
                 "voice": os.getenv("TTS_VOICE", "onyx"),
                 "input": text, "response_format": "mp3"},
        "provider": "openai",
    }


async def synthesize(text: str) -> str:
    req = build_request(text)
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.post(req["url"], headers=req["headers"], json=req["json"])
        r.raise_for_status()
        audio = r.content
    fd, path = tempfile.mkstemp(suffix=".mp3", prefix="eng_tts_")
    with os.fdopen(fd, "wb") as f:
        f.write(audio)
    return path
