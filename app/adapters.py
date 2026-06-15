"""Adapters between the capture layer's Lap and our analysis types.

The real gt7dashboard.Lap stores full per-tick channels:
  data_position_x / data_position_z, data_speed, data_throttle,
  data_braking, data_time (cumulative ms in the lap).
This turns one into a LapTrace so live laps feed straight into the
improvement analyzer and the baseline recorder — no manual JSON step.
"""
from __future__ import annotations

from typing import List, Optional

from app.analysis import LapTrace


def trace_from_gt_lap(lap, label: str = "") -> Optional[LapTrace]:
    x = list(getattr(lap, "data_position_x", []) or [])
    z = list(getattr(lap, "data_position_z", []) or [])
    speed = list(getattr(lap, "data_speed", []) or [])
    thr = list(getattr(lap, "data_throttle", []) or [])
    brk = list(getattr(lap, "data_braking", []) or [])
    t = list(getattr(lap, "data_time", []) or [])
    n = min(len(x), len(z), len(speed), len(thr), len(brk), len(t))
    if n < 10:
        return None
    return LapTrace(x[:n], z[:n], speed[:n], thr[:n], brk[:n], t[:n],
                    label or getattr(lap, "title", "") or "lap")


def baseline_samples_from_trace(trace: LapTrace):
    """Yield (x, z, speed) tuples for BaselineRecorder.add_sample."""
    return zip(trace.x, trace.z, trace.speed)
