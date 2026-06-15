"""Data sources for the dashboard.

Both providers expose the same surface:
    .telemetry -> TelemetryFrame   (current live frame)
    .laps      -> List[LapRecord]  (completed laps)
    .on_pit()  -> hook the engineer can call when a stop happens

SyntheticProvider simulates a realistic 40-minute enduro (deg, fuel burn,
pit stops, tyre temps) and advances on .step(dt). Used for local testing
with no console.

RealProvider lazily wraps gt7dashboard.GT7Communication so importing this
module never requires pycryptodome/pandas unless you actually capture.
"""
from __future__ import annotations

import random
from typing import Callable, List, Optional

from app.model import TelemetryFrame, LapRecord


class SyntheticProvider:
    """Simulate a 40-min race in accelerated time for testing the pipeline."""

    def __init__(self, *, base_lap_s: float = 95.0, deg_s_per_lap: float = 0.07,
                 fuel_per_lap: float = 3.2, fuel_capacity: float = 80.0,
                 start_fuel: float = 65.0, pit_loss_s: float = 22.0,
                 seed: int = 7):
        self.base_lap_s = base_lap_s
        self.deg_s_per_lap = deg_s_per_lap
        self.fuel_per_lap = fuel_per_lap
        self.pit_loss_s = pit_loss_s
        self._rng = random.Random(seed)

        self.telemetry = TelemetryFrame(
            connected=True, in_race=True, current_lap=1, total_laps=0,
            current_fuel=start_fuel, fuel_capacity=fuel_capacity,
            best_lap_ms=-1, last_lap_ms=-1, car_speed=180.0, throttle=100.0,
        )
        self.laps: List[LapRecord] = []
        self.lap_traces = []                 # List[LapTrace], one per completed lap
        self.on_pit_callbacks: List[Callable[[], None]] = []

        self._t = 0.0                 # race clock (s)
        self._lap_elapsed = 0.0       # time into current lap (s)
        self._stint_lap = 1           # lap index within stint
        self._lap_target = self._lap_time(self._stint_lap)
        self._stops_made = 0
        self._tyre_base = 75.0

    def add_pit_listener(self, cb: Callable[[], None]) -> None:
        self.on_pit_callbacks.append(cb)

    def _emit_trace(self, stint_lap: int) -> None:
        """Synthesize a realistic per-tick trace (oval + 2 corners) for this lap.

        Later stint laps carry slightly less corner speed (deg), so analysing the
        latest lap vs the fastest lap surfaces real loss zones.
        """
        import math
        from app.analysis import LapTrace
        N = 160
        a, b = 420.0, 260.0
        corner_pen = min(9.0, (stint_lap - 1) * 0.6) + self._rng.uniform(-0.5, 0.5)
        base = 230.0
        xs, zs, spd, tms = [], [], [], []
        t_acc, prev = 0.0, None
        for k in range(N + 1):
            u = k / N
            ang = 2 * math.pi * u
            x, z = a * math.cos(ang), b * math.sin(ang)
            dip = 0.0
            for cu, depth in ((0.25, 120.0), (0.75, 110.0)):
                d = abs(((u - cu + 0.5) % 1.0) - 0.5)
                if d < 0.08:
                    dip = max(dip, (depth + corner_pen) * (1 - d / 0.08))
            s = max(70.0, base - dip)
            if prev is not None:
                t_acc += math.hypot(x - prev[0], z - prev[1]) / (max(20.0, s) / 3.6)
            xs.append(x); zs.append(z); spd.append(s); tms.append(t_acc * 1000.0)
            prev = (x, z)
        thr, brk = [], []
        for i in range(len(spd)):
            ds = spd[min(i + 1, len(spd) - 1)] - spd[max(i - 1, 0)]
            brk.append(max(0.0, min(100.0, -ds * 8)))
            thr.append(100.0 if ds > -1 else 0.0)
        self.lap_traces.append(LapTrace(xs, zs, spd, thr, brk, tms,
                                        label=f"lap{self.telemetry.current_lap}"))

    def _lap_time(self, stint_lap: int) -> float:
        jitter = self._rng.uniform(-0.15, 0.25)
        return self.base_lap_s + self.deg_s_per_lap * (stint_lap - 1) + jitter

    def step(self, dt: float) -> None:
        """Advance the simulation by dt seconds of race time."""
        if not self.telemetry.in_race:
            return
        self._t += dt
        self._lap_elapsed += dt

        # burn fuel proportionally through the lap
        burn = self.fuel_per_lap * (dt / self._lap_target)
        self.telemetry.current_fuel = max(0.0, self.telemetry.current_fuel - burn)

        # tyre temps climb through a stint, peak ~ +18C
        self.telemetry.tyre_temp_fl = self._tyre_base + min(18, self._stint_lap * 1.6) + self._rng.uniform(-1, 1)
        self.telemetry.tyre_temp_fr = self.telemetry.tyre_temp_fl + self._rng.uniform(2, 5)  # loaded front
        self.telemetry.tyre_temp_rl = self._tyre_base + min(15, self._stint_lap * 1.3)
        self.telemetry.tyre_temp_rr = self.telemetry.tyre_temp_rl + self._rng.uniform(1, 3)

        # animate instantaneous channels around the lap so the live gauges move
        import math
        frac = (self._lap_elapsed / self._lap_target) if self._lap_target else 0.0
        dip = 0.0
        for cu, depth in ((0.25, 120.0), (0.75, 110.0)):
            dd = abs(((frac - cu + 0.5) % 1.0) - 0.5)
            if dd < 0.08:
                dip = max(dip, depth * (1 - dd / 0.08))
        spd = max(70.0, 230.0 - dip)
        self.telemetry.car_speed = spd
        self.telemetry.throttle = 100.0 if dip < 30 else max(0.0, 60.0 - dip)
        self.telemetry.brake = min(100.0, dip) if dip > 30 else 0.0
        self.telemetry.gear = max(1, min(6, int(spd // 40) + 1))
        self.telemetry.rpm = 3500.0 + (spd % 40) / 40.0 * 4500.0
        self.telemetry.boost = 0.6 if self.telemetry.throttle > 80 else 0.0
        self.telemetry.water_temp = 92.0
        self.telemetry.oil_temp = 104.0

        # complete a lap?
        if self._lap_elapsed >= self._lap_target:
            lap_ms = int(self._lap_target * 1000)
            consumed = self.fuel_per_lap + self._rng.uniform(-0.05, 0.05)
            outlier = False

            # decide a pit stop: when fuel would not cover ~2 more laps
            pit_now = (self.telemetry.current_fuel < self.fuel_per_lap * 1.3)
            if pit_now:
                # in-lap counts; simulate refuel to full + tyres, add pit loss next lap
                self.telemetry.current_fuel = self.telemetry.fuel_capacity
                self._stops_made += 1
                outlier = True
                for cb in self.on_pit_callbacks:
                    cb()

            self.laps.append(LapRecord(
                number=self.telemetry.current_lap,
                lap_finish_time_ms=lap_ms + (int(self.pit_loss_s * 1000) if outlier else 0),
                fuel_consumed=consumed,
                fuel_at_end=self.telemetry.current_fuel,
                stint_lap=self._stint_lap,
                is_outlier=outlier,
            ))
            self._emit_trace(self._stint_lap)

            # update best/last
            self.telemetry.last_lap_ms = lap_ms
            if self.telemetry.best_lap_ms < 0 or lap_ms < self.telemetry.best_lap_ms:
                self.telemetry.best_lap_ms = lap_ms

            # advance counters
            self.telemetry.current_lap += 1
            self._lap_elapsed = 0.0
            if pit_now:
                self._stint_lap = 1
                self._tyre_base = 75.0
            else:
                self._stint_lap += 1
            self._lap_target = self._lap_time(self._stint_lap)


class RealProvider:
    """Wrap the kept gt7dashboard capture thread, normalising to our model."""

    def __init__(self, playstation_ip: str):
        # Lazy import so this module stays light unless capture is used.
        from gt7dashboard.gt7communication import GT7Communication
        self.playstation_ip = playstation_ip
        self._comm = GT7Communication(playstation_ip)
        self._comm.start()
        self._last_lap_seen = 0
        self._stint_lap = 0
        self._laps: List[LapRecord] = []

    def stop(self) -> None:
        """Signal the capture thread to exit and release UDP 33740."""
        try:
            self._comm.stop()
        except Exception:
            pass


    @property
    def telemetry(self) -> TelemetryFrame:
        d = self._comm.last_data
        connected = self._comm.is_connected()
        if d is None:
            return TelemetryFrame(connected=connected)
        return TelemetryFrame(
            connected=connected,
            in_race=getattr(d, "in_race", False),
            is_paused=getattr(d, "is_paused", False),
            current_lap=getattr(d, "current_lap", 0) or 0,
            total_laps=getattr(d, "total_laps", 0) or 0,
            last_lap_ms=getattr(d, "last_lap", -1),
            best_lap_ms=getattr(d, "best_lap", -1),
            current_fuel=getattr(d, "current_fuel", 0.0),
            fuel_capacity=getattr(d, "fuel_capacity", 0.0),
            car_speed=getattr(d, "car_speed", 0.0),
            throttle=getattr(d, "throttle", 0.0),
            brake=getattr(d, "brake", 0.0),
            car_id=getattr(d, "car_id", 0),
            position_x=getattr(d, "position_x", 0.0),
            position_z=getattr(d, "position_z", 0.0),
            tyre_temp_fl=getattr(d, "tyre_temp_FL", 0.0),
            tyre_temp_fr=getattr(d, "tyre_temp_FR", 0.0),
            tyre_temp_rl=getattr(d, "tyre_temp_rl", 0.0),
            tyre_temp_rr=getattr(d, "tyre_temp_rr", 0.0),
            rpm=getattr(d, "rpm", 0.0),
            gear=getattr(d, "current_gear", 0) or 0,
            boost=getattr(d, "boost", 0.0),
            oil_temp=getattr(d, "oil_temp", 0.0),
            water_temp=getattr(d, "water_temp", 0.0),
        )

    @property
    def laps(self) -> List[LapRecord]:
        # Convert any newly-finished gt7 Laps into our LapRecord list.
        gt_laps = self._comm.get_laps()
        # gt7dashboard stores most-recent-first; normalise to chronological.
        chrono = list(reversed(gt_laps))
        self._laps = []
        stint_lap = 0
        for lp in chrono:
            consumed = getattr(lp, "fuel_consumed", -1)
            outlier = consumed is None or consumed < 0
            stint_lap = 1 if outlier else stint_lap + 1
            self._laps.append(LapRecord(
                number=getattr(lp, "number", 0),
                lap_finish_time_ms=int(getattr(lp, "lap_finish_time", 0)),
                fuel_consumed=max(0.0, consumed) if consumed and consumed > 0 else 0.0,
                fuel_at_end=getattr(lp, "fuel_at_end", 0.0),
                stint_lap=stint_lap,
                is_outlier=outlier,
            ))
        return self._laps

    def step(self, dt: float) -> None:  # parity with synthetic; real is push-driven
        pass

    @property
    def lap_traces(self):
        """Build LapTrace objects from completed gt7 Laps (full per-tick channels)."""
        from app.adapters import trace_from_gt_lap
        out = []
        for lp in reversed(self._comm.get_laps()):
            tr = trace_from_gt_lap(lp)
            if tr:
                out.append(tr)
        return out