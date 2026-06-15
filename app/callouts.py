"""Callout engine — the 'voice' of the race engineer.

Consumes the per-tick snapshot stream and emits short spoken lines only when
something meaningful changes, with priority + cooldown so it behaves like a real
race engineer on the radio rather than a chatterbox. Output is delivery-agnostic:
a Discord bot or the PWA speaks the same Callout objects.

Priorities: 0 CRITICAL (box now / fuel critical) > 1 WARN (save / deg / tyre)
            > 2 INFO (periodic fuel + pace) > 3 CHATTER (radio check / laps-to-go)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Callout:
    category: str
    text: str
    priority: int          # 0 highest
    ts: float = 0.0


class CalloutEngine:
    def __init__(self, *, fuel_update_laps: int = 3, deg_cliff_s: float = 0.15,
                 tyre_hot_c: float = 110.0):
        self.fuel_update_laps = fuel_update_laps
        self.deg_cliff_s = deg_cliff_s
        self.tyre_hot_c = tyre_hot_c
        # cooldowns per category (seconds of real time)
        self._cooldown = {
            "radio_check": 1e9, "box": 8.0, "fuel_save": 40.0, "fuel_critical": 25.0,
            "fuel_update": 1e9, "deg": 60.0, "tyre": 45.0, "laps_to_go": 1e9, "pace": 20.0,
        }
        self._last: dict[str, float] = {}
        self._prev: Optional[dict] = None
        self._box_armed = True
        self._last_fuel_update_lap = 0
        self._greeted = False

    def _ready(self, cat: str, now: float) -> bool:
        return (now - self._last.get(cat, -1e9)) >= self._cooldown.get(cat, 10.0)

    def _fire(self, out: List[Callout], cat: str, text: str, prio: int, now: float):
        out.append(Callout(cat, text, prio, now))
        self._last[cat] = now

    def ingest(self, snap: dict, now: float) -> List[Callout]:
        out: List[Callout] = []
        if not snap.get("in_race"):
            self._prev = snap
            return out

        # greeting once when the race/session starts
        if not self._greeted:
            self._greeted = True
            self._fire(out, "radio_check", "Radio check — engineer here, have a good one.", 3, now)

        et = snap.get("event_type")
        if et == "race":
            out += self._race_calls(snap, now)
        elif et == "test_run":
            out += self._test_calls(snap, now)
        elif et in ("time_trial", "reference_lap"):
            out += self._tt_calls(snap, now)

        # keep only the single highest-priority line per tick (radio discipline)
        if out:
            out.sort(key=lambda c: c.priority)
            out = [out[0]]
        self._prev = snap
        return out

    # ---- race ---------------------------------------------------------
    def _race_calls(self, s, now) -> List[Callout]:
        out: List[Callout] = []
        stops_left = s.get("stops_left")
        fll = s.get("fuel_laps_left")
        bal = s.get("fuel_balance_laps")
        cur = s.get("current_lap") or 0
        laps_left = s.get("laps_left_race")

        # re-arm the box call after a stop (stint reset / stops decreased)
        if self._prev and self._prev.get("event_type") == "race":
            if (s.get("stint_lap") or 0) <= 1 and (self._prev.get("stint_lap") or 0) > 1:
                self._box_armed = True

        # BOX — fuel-limited, or we've reached the latest safe pit lap, with a stop owed
        pit_by = s.get("pit_by_lap")
        box_due = (fll is not None and fll < 1.6) or (pit_by is not None and cur >= pit_by)
        if stops_left and box_due and self._box_armed and self._ready("box", now):
            self._fire(out, "box", "Box this lap, box, box.", 0, now)
            self._box_armed = False

        # fuel save / critical when no stop left to fix it
        if stops_left == 0 and bal is not None:
            if bal < -0.3 and self._ready("fuel_critical", now):
                tgt = s.get("fuel_save_target_l")
                extra = f" target {tgt} a lap." if tgt else ""
                self._fire(out, "fuel_critical", f"Fuel critical, we're {abs(bal):.1f} short — save now.{extra}", 0, now)
            elif bal < 0 and self._ready("fuel_save", now):
                self._fire(out, "fuel_save", "Fuel's marginal — lift and coast where you can.", 1, now)

        # deg cliff
        deg = s.get("deg_per_lap_s")
        if deg is not None and deg >= self.deg_cliff_s and self._ready("deg", now):
            self._fire(out, "deg", f"Tyres dropping off, {deg:.2f} a lap — manage the rears.", 1, now)

        # hot tyre
        temps = s.get("tyre_temps") or {}
        hot = [k.upper() for k, v in temps.items() if isinstance(v, (int, float)) and v >= self.tyre_hot_c]
        if hot and self._ready("tyre", now):
            self._fire(out, "tyre", f"{', '.join(hot)} running hot — ease the loading.", 1, now)

        # periodic fuel update every N laps
        if cur and cur != self._last_fuel_update_lap and cur % self.fuel_update_laps == 0:
            self._last_fuel_update_lap = cur
            if fll is not None:
                sign = "up" if (bal or 0) >= 0 else "down"
                self._fire(out, "fuel_update",
                           f"Fuel: {fll:.1f} laps in the tank, {sign} {abs(bal):.1f} on the race." if bal is not None
                           else f"Fuel: {fll:.1f} laps in the tank.", 2, now)

        # two to go
        if laps_left == 2 and self._ready("laps_to_go", now):
            self._fire(out, "laps_to_go", "Two laps to go — bring it home.", 3, now)

        return out

    # ---- test run -----------------------------------------------------
    def _test_calls(self, s, now) -> List[Callout]:
        out: List[Callout] = []
        done = s.get("stint_done") or 0
        target = s.get("stint_target") or 0
        deg = s.get("deg_per_lap_s")
        if target and done == target and self._ready("laps_to_go", now):
            fpl = s.get("fuel_per_lap_l")
            self._fire(out, "laps_to_go",
                       f"Stint target hit — {done} laps, {fpl} a lap, deg {deg} a lap.", 2, now)
        elif deg is not None and deg >= self.deg_cliff_s and self._ready("deg", now):
            self._fire(out, "deg", f"Deg reading {deg:.2f} a lap on this run.", 2, now)
        return out

    # ---- time trial ---------------------------------------------------
    def _tt_calls(self, s, now) -> List[Callout]:
        out: List[Callout] = []
        d = s.get("delta_last_to_ref_s")
        if d is not None and self._ready("pace", now):
            if d < -0.05:
                self._fire(out, "pace", f"That's a {abs(d):.2f} improvement — purple.", 2, now)
            elif d > 0.15:
                self._fire(out, "pace", f"Up {d:.2f} on the reference — find it in the slow stuff.", 2, now)
        return out
