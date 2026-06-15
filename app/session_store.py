"""Saved sessions: persist a finished session's lap summaries + the parity-
locked lap comparison so it can be browsed and re-opened later.

JSON store in the same per-user config dir as tracks.json, so it survives a
restart and stays writable inside a PyInstaller bundle. UI/persistence only —
nothing here is on the parity surface.
"""
from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import List, Optional


def _default_store() -> Path:
    try:
        from app.config import config_dir
        return config_dir() / "sessions.json"
    except Exception:
        return Path(__file__).parent.parent / "data" / "sessions.json"


DEFAULT_SESSION_STORE = _default_store()


@dataclass
class SessionRecord:
    id: str
    saved_at: float
    event_type: str
    track: str
    total_laps: int
    best_lap_ms: int
    laps: List[dict] = field(default_factory=list)   # number/time_ms/fuel/stint/outlier
    comparison: Optional[dict] = None                # comparison_traces + delta + zones

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "SessionRecord":
        return cls(**d)

    def summary(self) -> dict:
        return {"id": self.id, "saved_at": self.saved_at, "event_type": self.event_type,
                "track": self.track, "total_laps": self.total_laps,
                "best_lap_ms": self.best_lap_ms,
                "has_analysis": bool(self.comparison and self.comparison.get("available"))}


class SessionStore:
    def __init__(self, path: Path = DEFAULT_SESSION_STORE, cap: int = 100):
        self.path = Path(path)
        self.cap = cap
        self._sessions: List[SessionRecord] = []
        self.load()

    def load(self) -> None:
        if self.path.exists():
            try:
                raw = json.loads(self.path.read_text())
                self._sessions = [SessionRecord.from_dict(r) for r in raw]
            except Exception:
                self._sessions = []

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps([r.to_dict() for r in self._sessions], indent=1))

    def add(self, rec: SessionRecord) -> None:
        self._sessions.insert(0, rec)            # newest first
        del self._sessions[self.cap:]
        self.save()

    def summaries(self) -> List[dict]:
        return [r.summary() for r in self._sessions]

    def get(self, sid: str) -> Optional[SessionRecord]:
        return next((r for r in self._sessions if r.id == sid), None)

    def delete(self, sid: str) -> bool:
        before = len(self._sessions)
        self._sessions = [r for r in self._sessions if r.id != sid]
        if len(self._sessions) != before:
            self.save()
            return True
        return False