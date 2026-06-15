"""Event types and their parameter schemas.

The telemetry engine is told what kind of session it's collecting:
  - REFERENCE_LAP : capture a gold lap from a replay (basis for improvement analysis)
  - TEST_RUN      : gather stint data (deg/fuel) — the car-comparison workflow
  - TIME_TRIAL    : single-lap qualifying pace vs a reference
  - RACE          : full strategy engine (fuel-to-flag, pit window, …)

Each type declares a schema (list of ParamSpec) so the UI can render the right
form and the backend can validate. EventConfig holds validated values and can
emit a RaceConfig for the race strategy math.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, List, Optional

from app.model import RaceConfig


class EventType(str, Enum):
    REFERENCE_LAP = "reference_lap"
    TEST_RUN = "test_run"
    TIME_TRIAL = "time_trial"
    RACE = "race"
    BASELINE = "baseline"           # dev mode: map track dims + pit loss


TIRES = ["RS", "RM", "RH", "IM", "WET"]


@dataclass
class ParamSpec:
    key: str
    label: str
    kind: str                       # int | float | bool | enum | multi_enum | str
    default: Any
    unit: str = ""
    options: Optional[List[str]] = None
    help: str = ""

    def coerce(self, value: Any) -> Any:
        if value is None:
            return self.default
        if self.kind == "int":
            return int(value)
        if self.kind == "float":
            return float(value)
        if self.kind == "bool":
            return bool(value)
        if self.kind == "enum":
            if self.options and value not in self.options:
                raise ValueError(f"{self.key}={value!r} not in {self.options}")
            return value
        if self.kind == "multi_enum":
            vals = value if isinstance(value, list) else [value]
            if self.options:
                bad = [v for v in vals if v not in self.options]
                if bad:
                    raise ValueError(f"{self.key} has invalid {bad}, allowed {self.options}")
            return vals
        return str(value)

    def to_dict(self) -> dict:
        return {"key": self.key, "label": self.label, "kind": self.kind,
                "default": self.default, "unit": self.unit,
                "options": self.options, "help": self.help}


# --- the schemas -----------------------------------------------------------
EVENT_SCHEMAS: dict[EventType, List[ParamSpec]] = {
    EventType.REFERENCE_LAP: [
        ParamSpec("track_name", "Track", "str", "", help="Name to store the reference under"),
        ParamSpec("car", "Car", "str", ""),
        ParamSpec("from_replay", "Recording from replay", "bool", True),
    ],
    EventType.TEST_RUN: [
        ParamSpec("track_name", "Track", "str", ""),
        ParamSpec("car", "Car", "str", ""),
        ParamSpec("tire_compound", "Tire", "enum", "RH", options=TIRES),
        ParamSpec("start_fuel", "Start fuel", "float", 65.0, unit="L"),
        ParamSpec("fuel_multiplier", "Fuel mult.", "enum", "3", options=["1", "2", "3", "4", "5", "6"]),
        ParamSpec("tire_wear_multiplier", "Tire-wear mult.", "enum", "3", options=["1", "2", "3", "4", "5", "6"]),
        ParamSpec("target_stint_laps", "Target stint laps", "int", 10),
    ],
    EventType.TIME_TRIAL: [
        ParamSpec("track_name", "Track", "str", ""),
        ParamSpec("car", "Car", "str", ""),
        ParamSpec("tire_compound", "Tire", "enum", "RS", options=TIRES),
        ParamSpec("reference_track", "Reference lap (track)", "str", "",
                  help="Track name whose stored reference to delta against"),
    ],
    EventType.RACE: [
        ParamSpec("track_name", "Track", "str", ""),
        ParamSpec("car", "Car", "str", ""),
        ParamSpec("race_minutes", "Race length", "int", 40, unit="min"),
        ParamSpec("mandatory_stops", "Mandatory stops", "int", 1),
        ParamSpec("required_tires", "Required tires", "multi_enum", ["RS", "RM", "RH"], options=TIRES,
                  help="Compounds that must be used; RH stint is mandatory in this series"),
        ParamSpec("refuel_rate_lps", "Refuel rate", "float", 9.0, unit="L/s"),
        ParamSpec("pit_lane_loss_s", "Pit-lane loss", "float", 22.0, unit="s",
                  help="Auto-filled from track baseline when available"),
        ParamSpec("fuel_buffer_laps", "Fuel buffer", "float", 0.6, unit="laps"),
    ],
    EventType.BASELINE: [
        ParamSpec("track_name", "Track", "str", ""),
        ParamSpec("car", "Car", "str", ""),
        ParamSpec("measure_pit_loss", "Calibrate pit loss", "bool", True,
                  help="Run a normal lap then a pit lap to measure time loss"),
    ],
}


@dataclass
class EventConfig:
    type: EventType
    values: dict = field(default_factory=dict)

    @classmethod
    def build(cls, type: EventType | str, **overrides) -> "EventConfig":
        et = EventType(type)
        schema = EVENT_SCHEMAS[et]
        values = {}
        for spec in schema:
            raw = overrides.get(spec.key, spec.default)
            values[spec.key] = spec.coerce(raw)
        return cls(type=et, values=values)

    def get(self, key: str, default: Any = None) -> Any:
        return self.values.get(key, default)

    @property
    def records_strategy(self) -> bool:
        return self.type == EventType.RACE

    @property
    def records_stint(self) -> bool:
        return self.type in (EventType.TEST_RUN, EventType.RACE)

    @property
    def is_replay(self) -> bool:
        return self.type in (EventType.REFERENCE_LAP, EventType.BASELINE) and \
               bool(self.get("from_replay", self.type == EventType.REFERENCE_LAP))

    def race_config(self) -> RaceConfig:
        """Emit a RaceConfig for the strategy math (race mode)."""
        return RaceConfig(
            race_seconds=int(self.get("race_minutes", 40)) * 60,
            mandatory_stops=int(self.get("mandatory_stops", 1)),
            refuel_rate_lps=float(self.get("refuel_rate_lps", 9.0)),
            pit_lane_loss_s=float(self.get("pit_lane_loss_s", 22.0)),
            fuel_buffer_laps=float(self.get("fuel_buffer_laps", 0.6)),
        )

    def to_dict(self) -> dict:
        return {"type": self.type.value, "values": self.values}


def schemas_payload() -> dict:
    """Serialisable schema map for the UI to render config forms."""
    return {et.value: [s.to_dict() for s in specs] for et, specs in EVENT_SCHEMAS.items()}