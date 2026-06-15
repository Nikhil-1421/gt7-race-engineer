"""Track & car catalog for the session dropdowns.

A single JSON file drives the cascading Track/Car selectors on both surfaces:
the web dashboard fetches it from GET /catalog, and the Flutter app bundles
the same file as an asset. The file is user-populated; this loader is tolerant
of an absent or partial file (the UI falls back to free-text entry).

Lookup order (first that exists wins):
  1. <config_dir>/catalog.json   - per-user override, editable after install
  2. app/static/catalog.json     - shipped with the app (bundled by PyInstaller)
  3. <repo>/catalog.json         - dev convenience
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

_STATIC = Path(__file__).parent / "static" / "catalog.json"


def _candidates() -> List[Path]:
    paths: List[Path] = []
    try:
        from app.config import config_dir
        paths.append(config_dir() / "catalog.json")
    except Exception:
        pass
    paths.append(_STATIC)
    paths.append(Path(__file__).parent.parent / "catalog.json")
    return paths


def _is_real(s: str) -> bool:
    """Drop the underscore-prefixed placeholder entries from the template."""
    return bool(s) and not s.startswith("_")


def _clean(data: Dict[str, Any]) -> Dict[str, Any]:
    tracks = []
    for v in data.get("tracks", []):
        if not isinstance(v, dict):
            continue
        layouts = [l for l in v.get("layouts", []) if _is_real(l)]
        if layouts:
            tracks.append({"venue": v.get("venue", ""),
                           "region": v.get("region", ""),
                           "layouts": layouts})
    cars = []
    for c in data.get("cars", []):
        if not isinstance(c, dict):
            continue
        mfrs = []
        for m in c.get("manufacturers", []):
            cs = [x for x in m.get("cars", []) if _is_real(x)]
            if cs and _is_real(m.get("country", "")):
                mfrs.append({"country": m.get("country", ""), "cars": cs})
        if mfrs and _is_real(c.get("category", "")):
            cars.append({"category": c.get("category", ""), "manufacturers": mfrs})
    return {"tracks": tracks, "cars": cars}


def load_catalog() -> Dict[str, Any]:
    for p in _candidates():
        try:
            if p.exists():
                return _clean(json.loads(p.read_text()))
        except Exception:
            continue
    return {"tracks": [], "cars": []}


def track_names(data: Dict[str, Any] | None = None) -> List[str]:
    data = data or load_catalog()
    out: List[str] = []
    for v in data["tracks"]:
        out.extend(v["layouts"])
    return out


def car_names(data: Dict[str, Any] | None = None) -> List[str]:
    data = data or load_catalog()
    out: List[str] = []
    for c in data["cars"]:
        for m in c["manufacturers"]:
            out.extend(m["cars"])
    return out