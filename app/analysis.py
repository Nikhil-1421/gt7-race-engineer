"""Post-session analysis: where are you losing time, and why.

Given a target lap and a reference lap (each a LapTrace of position + speed +
throttle + brake + time), this:
  1. builds cumulative distance for each lap from position
  2. resamples both onto a common distance grid
  3. computes the delta-time trace (target time - reference time vs distance)
  4. segments the lap into loss zones (where you bleed time fastest)
  5. diagnoses each zone: braking point, min corner speed, throttle-on point,
     and coasting — turning "0.3s slower in sector 2" into an actionable note.

numpy is fine here: this is post-session, not the live hot path.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

import numpy as np


@dataclass
class LapTrace:
    """One lap's per-tick channels. x/z used for distance; speed in km/h; pedals 0-100."""
    x: List[float]
    z: List[float]
    speed: List[float]
    throttle: List[float]
    brake: List[float]
    t_ms: List[float]                       # cumulative time from lap start, ms
    label: str = ""

    def arrays(self):
        return (np.asarray(self.x, float), np.asarray(self.z, float),
                np.asarray(self.speed, float), np.asarray(self.throttle, float),
                np.asarray(self.brake, float), np.asarray(self.t_ms, float))


@dataclass
class ImprovementZone:
    start_m: float
    end_m: float
    time_lost_s: float
    sector: Optional[int]
    notes: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"start_m": round(self.start_m, 0), "end_m": round(self.end_m, 0),
                "time_lost_s": round(self.time_lost_s, 3), "sector": self.sector,
                "notes": self.notes}


def _cum_dist(x, z):
    d = np.zeros(len(x))
    if len(x) > 1:
        seg = np.hypot(np.diff(x), np.diff(z))
        d[1:] = np.cumsum(seg)
    return d


def _resample(dist, channel, grid):
    # ensure strictly increasing distance for interp
    keep = np.concatenate(([True], np.diff(dist) > 0))
    return np.interp(grid, dist[keep], channel[keep])


def _sector_of(d, sector_bounds):
    if not sector_bounds:
        return None
    for i, b in enumerate(sector_bounds):
        if d <= b:
            return i + 1
    return len(sector_bounds) + 1


def analyze(target: LapTrace, reference: LapTrace,
            sector_bounds_m: Optional[List[float]] = None,
            n_grid: int = 800, n_zones: int = 5,
            min_zone_loss_s: float = 0.03) -> dict:
    tx, tz, ts, tth, tbr, tt = target.arrays()
    rx, rz, rs, rth, rbr, rt = reference.arrays()

    td, rd = _cum_dist(tx, tz), _cum_dist(rx, rz)
    L = min(td[-1], rd[-1])
    grid = np.linspace(0, L, n_grid)

    # time-at-distance, then delta
    t_time = _resample(td, tt, grid)
    r_time = _resample(rd, rt, grid)
    delta = (t_time - r_time) / 1000.0          # seconds; positive = target slower
    delta -= delta[0]                            # zero at start line
    total_delta = float(delta[-1])

    # channels on the common grid
    t_speed = _resample(td, ts, grid)
    r_speed = _resample(rd, rs, grid)
    t_brake = _resample(td, tbr, grid)
    r_brake = _resample(rd, rbr, grid)
    t_thr = _resample(td, tth, grid)
    r_thr = _resample(rd, rth, grid)

    # rate of time loss; positive => losing here
    dloss = np.diff(delta, prepend=delta[0])

    # group contiguous losing regions
    losing = dloss > 0
    zones: List[ImprovementZone] = []
    i = 0
    while i < len(grid):
        if not losing[i]:
            i += 1
            continue
        j = i
        while j < len(grid) and losing[j]:
            j += 1
        lost = float(delta[j - 1] - delta[i])
        if lost >= min_zone_loss_s:
            zones.append(_diagnose(grid, i, j, lost, sector_bounds_m,
                                   t_speed, r_speed, t_brake, r_brake, t_thr, r_thr))
        i = j

    zones.sort(key=lambda z: z.time_lost_s, reverse=True)
    top = zones[:n_zones]

    return {
        "target": target.label, "reference": reference.label,
        "total_delta_s": round(total_delta, 3),
        "lap_length_m": round(float(L), 0),
        "n_loss_zones": len(zones),
        "improvements": [z.to_dict() for z in top],
        "delta_trace": {"dist_m": [round(float(d), 1) for d in grid[::20]],
                        "delta_s": [round(float(v), 3) for v in delta[::20]]},
    }


def _diagnose(grid, i, j, lost, sectors,
              t_speed, r_speed, t_brake, r_brake, t_thr, r_thr) -> ImprovementZone:
    seg = slice(i, j)
    start_m, end_m = float(grid[i]), float(grid[j - 1])
    notes: List[str] = []

    BRAKE_TH, THR_TH = 8.0, 80.0

    def first_dist(mask):
        idx = np.nonzero(mask[seg])[0]
        return grid[i + idx[0]] if len(idx) else None

    # braking point: where each first gets meaningfully on the brakes
    tb = first_dist(t_brake > BRAKE_TH)
    rb = first_dist(r_brake > BRAKE_TH)
    if tb is not None and rb is not None:
        d = tb - rb
        if d < -4:
            notes.append(f"Braking {abs(d):.0f} m too early")
        elif d > 4:
            notes.append(f"Braking {d:.0f} m later than reference (good — or overdriving)")

    # min corner speed
    t_min = float(np.min(t_speed[seg]))
    r_min = float(np.min(r_speed[seg]))
    if r_min - t_min > 3:
        notes.append(f"Carrying {r_min - t_min:.0f} km/h less mid-corner")

    # throttle-on point (first time near-full throttle)
    tt_on = first_dist(t_thr > THR_TH)
    rt_on = first_dist(r_thr > THR_TH)
    if tt_on is not None and rt_on is not None and tt_on - rt_on > 5:
        notes.append(f"Back to full throttle {tt_on - rt_on:.0f} m later")

    # coasting (off both pedals)
    coast = np.mean((t_thr[seg] < 5) & (t_brake[seg] < 5))
    if coast > 0.18:
        notes.append(f"Coasting {coast*100:.0f}% of this zone — commit earlier")

    if not notes:
        notes.append("Small line/exit loss")

    return ImprovementZone(start_m=start_m, end_m=end_m, time_lost_s=lost,
                           sector=_sector_of(start_m, sectors), notes=notes)


def format_report(rep: dict) -> str:
    lines = [f"Post-session: {rep['target']} vs {rep['reference']}  "
             f"({rep['lap_length_m']:.0f} m lap)",
             f"Total delta: {rep['total_delta_s']:+.3f} s   "
             f"({rep['n_loss_zones']} loss zones)\n",
             "Top areas to find time:"]
    for n, z in enumerate(rep["improvements"], 1):
        sect = f" [S{z['sector']}]" if z["sector"] else ""
        lines.append(f"  {n}. {z['start_m']:.0f}-{z['end_m']:.0f} m{sect}  "
                     f"−{z['time_lost_s']:.3f} s")
        for note in z["notes"]:
            lines.append(f"       • {note}")
    return "\n".join(lines)
