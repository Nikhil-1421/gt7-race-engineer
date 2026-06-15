"""Cloud speech-to-text for the two-way engineer (driver questions).

Uses OpenAI Whisper (whisper-1) so one OPENAI_API_KEY covers both TTS and STT.
transcribe(wav_path) -> recognised text (lowercased upstream by the intent parser).
"""
from __future__ import annotations

import os

import httpx


async def transcribe(wav_path: str) -> str:
    key = os.getenv("OPENAI_API_KEY", "")
    if not key:
        return ""
    with open(wav_path, "rb") as f:
        files = {"file": (os.path.basename(wav_path), f, "audio/wav")}
        data = {"model": os.getenv("STT_MODEL", "whisper-1"),
                "language": os.getenv("STT_LANG", "en")}
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {key}"},
                files=files, data=data,
            )
    if r.status_code != 200:
        return ""
    return (r.json().get("text") or "").strip()
