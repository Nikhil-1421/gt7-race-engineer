"""Event-aware session engineer.

Dispatches the per-frame compute on the event type:
  RACE         -> full strategy (fuel-to-flag, pit window, deg, pace)  [v1 math, unchanged]
  TEST_RUN     -> stint deg + fuel-per-lap + projected stint, pace
  TIME_TRIAL   -> pace + live delta to a stored reference lap
  REFERENCE_LAP/BASELINE -> minimal pace; recording handled elsewhere

Every mode returns an "event_type" key plus a "cards" list telling the UI which
panels are relevant, so the phone shows only what matters for the session.
"""
from __future__ import annotations

import math
from typing import List, Optional

from app.model import RaceConfig, TelemetryFrame, LapRecord, fmt_ms, fmt_clock
from app.events import EventConfig, EventType


def _linear_slope(xs: List[float], ys: List[float]) -> Optional[float]:
    n = len(xs)
    if n < 2:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    return None if den == 0 else num / den


class SessionEngineer:
    def __init__(self, event: EventConfig, reference: Optional[object] = None):
        self.event = event
        self.reference = reference                 # duck-typed: .best_lap_ms, .sector_distances
        self.race_cfg: RaceConfig = event.race_config() if event.type == EventType.RACE else RaceConfig()
        self._race_start_t: Optional[float] = None
        self._stops_made = 0

    @classmethod
    def for_race(cls, cfg: RaceConfig) -> "SessionEngineer":
        ev = EventConfig(type=EventType.RACE, values={
            "race_minutes": cfg.race_seconds // 60, "mandatory_stops": cfg.mandatory_stops,
            "refuel_rate_lps": cfg.refuel_rate_lps, "pit_lane_loss_s": cfg.pit_lane_loss_s,
            "fuel_buffer_laps": cfg.fuel_buffer_laps})
        e = cls(ev)
        e.race_cfg = cfg
        return e

    def notify_pit(self) -> None:
        self._stops_made += 1

    # ---- shared helpers -------------------------------------------------
    def _clean(self, laps):
        return [lp for lp in laps if not lp.is_outlier and lp.lap_finish_time_ms > 0]

    def _elapsed(self, now, tel):
        if tel.in_race and self._race_start_t is None:
            self._race_start_t = now
        return 0.0 if self._race_start_t is None else now - self._race_start_t

    def _stint_tail(self, clean):
        stint = [lp for lp in clean if lp.stint_lap > 0]
        tail = []
        for lp in reversed(stint):
            if tail and lp.stint_lap >= tail[-1].stint_lap:
                break
            tail.append(lp)
        tail.reverse()
        return tail

    def _pace_block(self, tel, recent):
        avg_ms = sum(lp.lap_finish_time_ms for lp in recent) / len(recent) if recent else None
        last_delta = (tel.last_lap_ms - tel.best_lap_ms
                      if tel.last_lap_ms > 0 and tel.best_lap_ms > 0 else None)
        return {
            "current_lap": tel.current_lap,
            "last_lap_str": fmt_ms(tel.last_lap_ms),
            "best_lap_str": fmt_ms(tel.best_lap_ms),
            "avg_lap_str": fmt_ms(int(avg_ms)) if avg_ms else "--:--.---",
            "last_delta_s": round(last_delta / 1000.0, 3) if last_delta is not None else None,
            "speed_kmh": round(tel.car_speed, 0),
        }, avg_ms

    def _deg_block(self, clean, laps_left):
        tail = self._stint_tail(clean)
        deg = proj_ms = None
        if len(tail) >= self.race_cfg.deg_stint_min_laps:
            xs = [float(lp.stint_lap) for lp in tail]
            ys = [lp.lap_finish_time_ms / 1000.0 for lp in tail]
            slope = _linear_slope(xs, ys)
            if slope is not None:
                deg = round(slope, 3)
                if laps_left:
                    proj_ms = int((ys[-1] + slope * laps_left) * 1000)
        stint_lap = tail[-1].stint_lap + 1 if tail else 0
        return {
            "stint_lap": stint_lap,
            "deg_per_lap_s": deg,
            "proj_end_lap_str": fmt_ms(proj_ms) if proj_ms else None,
        }

    # ---- mode: RACE (v1 strategy math, intact) --------------------------
    def _race(self, tel, clean, recent, avg_ms, now):
        cfg = self.race_cfg
        fuel_laps = [lp for lp in recent if lp.fuel_consumed > 0]
        fpl = sum(lp.fuel_consumed for lp in fuel_laps) / len(fuel_laps) if fuel_laps else None

        elapsed = self._elapsed(now, tel)
        time_left = max(0.0, cfg.race_seconds - elapsed)
        avg_s = (avg_ms / 1000.0) if avg_ms else None
        laps_left = math.ceil(time_left / avg_s) if avg_s and avg_s > 0 else None

        fuel_laps_left = tel.current_fuel / fpl if fpl else None
        need = laps_left * fpl if (laps_left is not None and fpl) else None
        bal_l = tel.current_fuel - need if need is not None else None
        bal_laps = bal_l / fpl if (bal_l is not None and fpl) else None

        save = None
        if laps_left and laps_left > 0 and fpl:
            ach = tel.current_fuel / laps_left
            if ach < fpl:
                save = round(ach, 2)

        stops_left = max(0, cfg.mandatory_stops - self._stops_made)
        refuel_l = refuel_t = None
        if need is not None and fpl:
            target = need + cfg.fuel_buffer_laps * fpl
            add = max(0.0, min(target - tel.current_fuel, max(0.0, tel.fuel_capacity - tel.current_fuel)))
            refuel_l = round(add, 1)
            refuel_t = round(add / cfg.refuel_rate_lps + cfg.pit_lane_loss_s, 1)
        pit_by = None
        if fuel_laps_left is not None:
            pit_by = tel.current_lap + max(0, math.floor(fuel_laps_left - cfg.fuel_buffer_laps))

        alert, msg = "ok", ""
        if bal_laps is not None and stops_left == 0:
            if bal_laps < -0.2:
                alert, msg = "danger", "SHORT on fuel — save now"
            elif bal_laps < 0:
                alert, msg = "warn", "Marginal fuel — lift & coast"
        if fuel_laps_left is not None and fuel_laps_left < 1.5 and stops_left > 0:
            alert, msg = "warn", "Box this lap — fuel low"

        out = {
            "time_remaining_s": round(time_left, 1), "time_remaining_str": fmt_clock(time_left),
            "laps_left_race": laps_left,
            "fuel_now_l": round(tel.current_fuel, 1), "fuel_pct": round(tel.fuel_pct, 1),
            "fuel_per_lap_l": round(fpl, 2) if fpl else None,
            "fuel_laps_left": round(fuel_laps_left, 1) if fuel_laps_left is not None else None,
            "fuel_balance_l": round(bal_l, 1) if bal_l is not None else None,
            "fuel_balance_laps": round(bal_laps, 1) if bal_laps is not None else None,
            "fuel_save_target_l": save,
            "stops_left": stops_left, "pit_by_lap": pit_by,
            "refuel_for_finish_l": refuel_l, "refuel_time_s": refuel_t,
            "alert": alert, "alert_msg": msg,
        }
        out.update(self._deg_block(clean, laps_left))
        out["cards"] = ["fuel", "pit", "pace", "deg", "tyres"]
        return out

    # ---- mode: TEST_RUN -------------------------------------------------
    def _test(self, tel, clean, recent):
        fuel_laps = [lp for lp in recent if lp.fuel_consumed > 0]
        fpl = sum(lp.fuel_consumed for lp in fuel_laps) / len(fuel_laps) if fuel_laps else None
        target = int(self.event.get("target_stint_laps", 10))
        tail = self._stint_tail(clean)
        out = {
            "tire_compound": self.event.get("tire_compound", "RH"),
            "fuel_per_lap_l": round(fpl, 2) if fpl else None,
            "fuel_now_l": round(tel.current_fuel, 1), "fuel_pct": round(tel.fuel_pct, 1),
            "stint_target": target, "stint_done": len(tail),
            "fuel_range_laps": round(tel.current_fuel / fpl, 1) if fpl else None,
            "alert": "ok", "alert_msg": "",
        }
        out.update(self._deg_block(clean, laps_left=target))
        out["cards"] = ["test", "pace", "deg", "tyres"]
        return out

    # ---- mode: TIME_TRIAL / REFERENCE ----------------------------------
    def _time_trial(self, tel):
        ref_ms = getattr(self.reference, "best_lap_ms", None) if self.reference else None
        delta = (tel.best_lap_ms - ref_ms) / 1000.0 if (ref_ms and tel.best_lap_ms > 0) else None
        last_delta = (tel.last_lap_ms - ref_ms) / 1000.0 if (ref_ms and tel.last_lap_ms > 0) else None
        out = {
            "tire_compound": self.event.get("tire_compound", "RS"),
            "reference_lap_str": fmt_ms(ref_ms) if ref_ms else "no reference",
            "delta_best_to_ref_s": round(delta, 3) if delta is not None else None,
            "delta_last_to_ref_s": round(last_delta, 3) if last_delta is not None else None,
            "alert": "ok", "alert_msg": "",
        }
        out["cards"] = ["timetrial", "pace", "tyres"]
        return out

    # ---- entrypoint -----------------------------------------------------
    def snapshot(self, tel: TelemetryFrame, laps: List[LapRecord], now: float) -> dict:
        clean = self._clean(laps)
        recent = clean[-self.race_cfg.clean_lap_window:]
        base, avg_ms = self._pace_block(tel, recent)
        base.update({
            "connected": tel.connected, "in_race": tel.in_race, "paused": tel.is_paused,
            "event_type": self.event.type.value,
            "track_name": self.event.get("track_name", ""),
            "tyre_temps": {
                "fl": round(tel.tyre_temp_fl, 1), "fr": round(tel.tyre_temp_fr, 1),
                "rl": round(tel.tyre_temp_rl, 1), "rr": round(tel.tyre_temp_rr, 1)},
        })

        if self.event.type == EventType.RACE:
            base.update(self._race(tel, clean, recent, avg_ms, now))
        elif self.event.type == EventType.TEST_RUN:
            base.update(self._test(tel, clean, recent))
        elif self.event.type in (EventType.TIME_TRIAL, EventType.REFERENCE_LAP):
            base.update(self._time_trial(tel))
        else:  # BASELINE
            base["cards"] = ["pace"]
            base["alert"], base["alert_msg"] = "ok", "Baseline recording"
        return base


def RaceEngineer(cfg: RaceConfig) -> SessionEngineer:
    """Back-compat alias for v1 callers/tests."""
    return SessionEngineer.for_race(cfg)
