#!/usr/bin/env python3
"""Post-session improvement analysis from two logged lap traces.

Usage:
    python -m tools.analyze_cli my_lap.json reference_lap.json [--sectors 1000 2000]

Each JSON file is an object with arrays: x, z, speed, throttle, brake, t_ms
(t_ms = cumulative time from lap start, in milliseconds). These are exactly the
per-tick channels gt7dashboard's Lap stores (data_position_x/z, data_speed,
data_throttle, data_braking, data_time), so an adapter can dump them straight
from a recorded session.
"""
import argparse
import json
import sys
from pathlib import Path

# allow running from repo root
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app.analysis import LapTrace, analyze, format_report   # noqa: E402


def load(path: str, label: str) -> LapTrace:
    d = json.loads(Path(path).read_text())
    return LapTrace(d["x"], d["z"], d["speed"], d["throttle"], d["brake"], d["t_ms"], label)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("reference")
    ap.add_argument("--sectors", nargs="*", type=float, default=None,
                    help="sector boundary distances in metres")
    ap.add_argument("--json", action="store_true", help="emit raw JSON report")
    args = ap.parse_args()

    rep = analyze(load(args.target, Path(args.target).stem),
                  load(args.reference, Path(args.reference).stem),
                  sector_bounds_m=args.sectors)
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        print(format_report(rep))


if __name__ == "__main__":
    main()
