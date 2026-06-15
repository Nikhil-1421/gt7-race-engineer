"""Track baselines: map a track's geometry and pit loss once, reuse forever.

BASELINE / REFERENCE_LAP mode feeds position+speed samples to BaselineRecorder.
On lap completion it computes track length and bounding dimensions from the
position trace, stores a downsampled reference line, and (optionally) calibrates
pit-lane loss from a normal lap vs a pit lap. Everything persists to
data/tracks.json so the race strategy engine can auto-fill pit_lane_loss_s.
"""
from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

def _default_store() -> Path:
    """Persist where the packaged app can actually write AND where data
    survives a restart: the same per-user config dir config.py uses, NOT a
    path next to the code (read-only / temporary inside a PyInstaller bundle —
    which is why saved references vanished when the desktop app was closed)."""
    try:
        from app.config import config_dir
        return config_dir() / "tracks.json"
    except Exception:
        return Path(__file__).parent.parent / "data" / "tracks.json"


DEFAULT_STORE = _default_store()


def _key(name: str) -> str:
    """Canonical match key: case- and whitespace-insensitive, so 'Red Bull
    Ring', 'red bull ring', and ' Red  Bull  Ring ' resolve to one reference."""
    return " ".join((name or "").split()).casefold()


@dataclass
class TrackBaseline:
    name: str
    length_m: float = 0.0
    width_m: float = 0.0                 # bounding box X extent
    depth_m: float = 0.0                 # bounding box Z extent
    pit_loss_s: Optional[float] = None
    best_lap_ms: int = -1
    sector_distances_m: List[float] = field(default_factory=list)
    # downsampled centerline for the improvement analyzer / map: [(dist_m, x, z, speed_kmh)]
    reference_line: List[Tuple[float, float, float, float]] = field(default_factory=list)
    recorded_at: float = 0.0

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "TrackBaseline":
        d = dict(d)
        d["reference_line"] = [tuple(p) for p in d.get("reference_line", [])]
        return cls(**d)


class TrackStore:
    def __init__(self, path: Path = DEFAULT_STORE):
        self.path = Path(path)
        self._tracks: Dict[str, TrackBaseline] = {}
        self.load()

    def load(self) -> None:
        if self.path.exists():
            raw = json.loads(self.path.read_text())
            # re-key by canonical name so legacy/raw keys normalize on load
            self._tracks = {}
            for v in raw.values():
                bl = TrackBaseline.from_dict(v)
                self._tracks[_key(bl.name)] = bl

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(
            {k: v.to_dict() for k, v in self._tracks.items()}, indent=2))

    def get(self, name: str) -> Optional[TrackBaseline]:
        return self._tracks.get(_key(name))

    def put(self, baseline: TrackBaseline) -> None:
        self._tracks[_key(baseline.name)] = baseline
        self.save()

    def names(self) -> List[str]:
        return sorted((bl.name for bl in self._tracks.values()), key=str.casefold)


def _cumulative_distance(xs: List[float], zs: List[float]) -> List[float]:
    dist = [0.0]
    for i in range(1, len(xs)):
        d = math.hypot(xs[i] - xs[i - 1], zs[i] - zs[i - 1])
        dist.append(dist[-1] + d)
    return dist


def _downsample(samples: List[Tuple[float, float, float, float]], n: int = 400):
    if len(samples) <= n:
        return samples
    step = len(samples) / n
    return [samples[int(i * step)] for i in range(n)]


class BaselineRecorder:
    """Accumulate one lap of position/speed and produce a TrackBaseline."""

    def __init__(self, track_name: str, n_sectors: int = 3):
        self.track_name = track_name
        self.n_sectors = n_sectors
        self.reset()

    def reset(self) -> None:
        self._xs: List[float] = []
        self._zs: List[float] = []
        self._spd: List[float] = []

    def add_sample(self, x: float, z: float, speed_kmh: float) -> None:
        self._xs.append(x)
        self._zs.append(z)
        self._spd.append(speed_kmh)

    def finalize(self, lap_ms: int) -> TrackBaseline:
        if len(self._xs) < 3:
            raise ValueError("not enough samples to build a baseline")
        dist = _cumulative_distance(self._xs, self._zs)
        length = dist[-1]
        width = max(self._xs) - min(self._xs)
        depth = max(self._zs) - min(self._zs)
        # even-distance sector splits
        sectors = [length * (i + 1) / self.n_sectors for i in range(self.n_sectors - 1)]
        line = list(zip(dist, self._xs, self._zs, self._spd))
        return TrackBaseline(
            name=self.track_name,
            length_m=round(length, 1),
            width_m=round(width, 1),
            depth_m=round(depth, 1),
            best_lap_ms=lap_ms,
            sector_distances_m=[round(s, 1) for s in sectors],
            reference_line=_downsample(line),
            recorded_at=time.time(),
        )

    @staticmethod
    def measure_pit_loss(normal_lap_ms: int, pit_lap_ms: int, refuel_s: float = 0.0) -> float:
        """Pit-lane time loss = (pit lap - normal lap) minus any stationary refuel time.

        Drive a representative normal lap, then a lap where you pit (no/again refuel).
        The delta is the time the pit lane itself costs vs staying out.
        """
        return round((pit_lap_ms - normal_lap_ms) / 1000.0 - refuel_s, 1)