"""Voice intent parsing for the two-way engineer.

Turns a transcribed driver utterance into a spoken answer, sourced from the
live engineer snapshot. Pure and testable — no audio, no network.

Design for a noisy open mic with no Discord noise suppression on PS5:
  - require a wake word ("engineer") so we don't react to chatter/engine noise
  - then scan the whole utterance for intent keywords (STT often garbles word
    order), pick the best match, and answer from the snapshot
"""
from __future__ import annotations

from typing import Optional

WAKE_WORDS = ("engineer", "engine ear", "engineering")   # common STT mishears

# intent -> trigger keywords
INTENTS = {
    "fuel":   ("fuel", "gas", "petrol", "tank"),
    "pit":    ("pit", "box", "stop", "stops", "pitstop"),
    "tyres":  ("tyre", "tire", "tyres", "tires", "temps", "rubber", "grip"),
    "pace":   ("pace", "lap time", "laptime", "delta", "last lap", "how am i", "doing"),
    "time":   ("time", "how long", "laps left", "how many laps", "remaining"),
    "deg":    ("deg", "degradation", "wear", "dropping", "falling off"),
    "status": ("status", "report", "update", "looking", "rundown"),
}


def _has_wake(text: str) -> bool:
    return any(w in text for w in WAKE_WORDS)


def _pick_intent(text: str) -> Optional[str]:
    best, best_hits = None, 0
    for intent, kws in INTENTS.items():
        hits = sum(1 for k in kws if k in text)
        if hits > best_hits:
            best, best_hits = intent, hits
    return best


def _n(v, suffix="", none="unknown"):
    return f"{v}{suffix}" if v is not None else none


def answer(intent: str, s: dict) -> str:
    if intent == "fuel":
        fll = s.get("fuel_laps_left"); bal = s.get("fuel_balance_laps")
        save = s.get("fuel_save_target_l"); stops = s.get("stops_left")
        parts = [f"{fll} laps of fuel in the tank" if fll is not None else "fuel unknown"]
        if bal is not None:
            parts.append(f"{'up' if bal >= 0 else 'down'} {abs(bal)} on the race")
        if save:
            parts.append(f"save target {save} a lap")
        elif stops:
            parts.append(f"{stops} stop still to take")
        return ", ".join(parts) + "."
    if intent == "pit":
        pit_by = s.get("pit_by_lap"); stops = s.get("stops_left")
        add = s.get("refuel_for_finish_l"); t = s.get("refuel_time_s")
        if not stops:
            return "All stops done — you're clear to run to the flag."
        msg = f"{stops} stop to take"
        if pit_by is not None:
            msg += f", box by lap {pit_by}"
        if add is not None:
            msg += f"; we'll put in {add} litres, about {t} seconds"
        return msg + "."
    if intent == "tyres":
        t = s.get("tyre_temps") or {}; deg = s.get("deg_per_lap_s")
        temps = ", ".join(f"{k.upper()} {round(v)}" for k, v in t.items()) if t else "no tyre data"
        tail = f", deg {deg} a lap" if deg is not None else ""
        return f"Tyres: {temps}{tail}."
    if intent == "pace":
        last = s.get("last_lap_str"); best = s.get("best_lap_str")
        d = s.get("last_delta_s"); avg = s.get("avg_lap_str")
        msg = f"Last lap {last}, best {best}"
        if d is not None:
            msg += f", {'up' if d > 0 else 'down'} {abs(d)} on your best"
        if avg and avg != "--:--.---":
            msg += f", averaging {avg}"
        return msg + "."
    if intent == "time":
        tr = s.get("time_remaining_str"); ll = s.get("laps_left_race")
        return f"{_n(tr, none='time unknown')} remaining, about {_n(ll, ' laps', 'unknown')}."
    if intent == "deg":
        deg = s.get("deg_per_lap_s"); proj = s.get("proj_end_lap_str")
        if deg is None:
            return "Not enough laps yet to read the degradation."
        tail = f", on for {proj} by stint end" if proj else ""
        return f"Tyres dropping {deg} a lap{tail}."
    if intent == "status":
        tr = s.get("time_remaining_str"); fll = s.get("fuel_laps_left")
        pit_by = s.get("pit_by_lap"); d = s.get("last_delta_s")
        bits = []
        if tr:
            bits.append(f"{tr} to go")
        if fll is not None:
            bits.append(f"{fll} laps of fuel")
        if pit_by is not None and s.get("stops_left"):
            bits.append(f"box by lap {pit_by}")
        if d is not None:
            bits.append(f"{'up' if d > 0 else 'down'} {abs(d)} on your best")
        return "Status: " + ", ".join(bits) + "." if bits else "Status: nothing to report yet."
    return "Say again? Try fuel, tyres, pit, pace, time, or status."


def parse(transcript: str, snapshot: dict) -> Optional[str]:
    """Return a spoken answer, or None if no wake word / not for us."""
    if not transcript:
        return None
    text = transcript.lower().strip()
    if not _has_wake(text):
        return None
    intent = _pick_intent(text)
    if intent is None:
        return "Engineer here — say fuel, tyres, pit, pace, time, or status."
    return answer(intent, snapshot)
