"""Core data model for the GT7 race-engineer dashboard.

Deliberately dependency-free so the compute layer and the synthetic test
stream stay importable without pycryptodome / pandas / scipy. The real
capture path (providers.RealProvider) lazily imports the gt7dashboard package.

Attribute names on TelemetryFrame / LapRecord deliberately mirror the fields
exposed by gt7dashboard.GTData / Lap so the engineer code is identical whether
data comes from a real PS5 or the synthetic generator.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class RaceConfig:
    """The regulations for the event. Defaults match the 40-min enduro spec."""
    race_seconds: int = 40 * 60            # timed race length
    mandatory_stops: int = 1               # required pit stops
    refuel_rate_lps: float = 9.0           # litres per second (the "9L" setting)
    pit_lane_loss_s: float = 22.0          # time lost in pit lane vs staying out (track-dependent)
    fuel_buffer_laps: float = 0.6          # safety margin so you don't run dry on the in-lap
    clean_lap_window: int = 5              # how many recent laps to average for pace/fuel
    deg_stint_min_laps: int = 4            # need this many stint laps before projecting deg


@dataclass
class TelemetryFrame:
    """A single decoded packet's worth of live state (the bits we use)."""
    connected: bool = False
    in_race: bool = False
    is_paused: bool = False
    current_lap: int = 0                   # lap number in progress (GT7: 1-based once racing)
    total_laps: int = 0
    last_lap_ms: int = -1                  # last completed lap time in ms (-1 = none yet)
    best_lap_ms: int = -1
    current_fuel: float = 0.0              # litres (same unit as capacity)
    fuel_capacity: float = 0.0
    car_speed: float = 0.0                 # km/h
    throttle: float = 0.0                  # 0-100
    brake: float = 0.0                     # 0-100
    car_id: int = 0
    position_x: float = 0.0                # for baseline mapping / track distance
    position_z: float = 0.0
    tyre_temp_fl: float = 0.0
    tyre_temp_fr: float = 0.0
    tyre_temp_rl: float = 0.0
    tyre_temp_rr: float = 0.0
    rpm: float = 0.0
    gear: int = 0
    boost: float = 0.0
    oil_temp: float = 0.0
    water_temp: float = 0.0

    @property
    def fuel_pct(self) -> float:
        if self.fuel_capacity <= 0:
            return 0.0
        return 100.0 * self.current_fuel / self.fuel_capacity


@dataclass
class LapRecord:
    """A completed lap. Mirrors gt7dashboard.Lap's relevant fields."""
    number: int
    lap_finish_time_ms: int                # completed lap time
    fuel_consumed: float                   # litres used this lap
    fuel_at_end: float                     # litres remaining at line
    stint_lap: int = 0                     # lap index within the current stint (1-based)
    is_outlier: bool = False               # pit in/out lap or anomaly -> excluded from averages


def fmt_ms(ms: Optional[int]) -> str:
    """Format milliseconds as m:ss.mmm, or '--:--.---' when unavailable."""
    if ms is None or ms < 0:
        return "--:--.---"
    total = ms / 1000.0
    m = int(total // 60)
    s = total - m * 60
    return f"{m}:{s:06.3f}"


def fmt_clock(seconds: float) -> str:
    """Format a countdown as M:SS (clamped at zero)."""
    seconds = max(0.0, seconds)
    m = int(seconds // 60)
    s = int(seconds % 60)
    return f"{m}:{s:02d}"