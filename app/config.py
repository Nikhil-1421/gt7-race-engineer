"""Persistent user config (stdlib only — no new dependencies).

Stores the PS5 IP and desktop preferences so the double-clickable app
remembers setup between launches. Location follows platform convention:

  macOS    ~/Library/Application Support/GT7RaceEngineer/config.json
  Windows  %APPDATA%/GT7RaceEngineer/config.json
  Linux    ~/.config/gt7-race-engineer/config.json   (or $XDG_CONFIG_HOME)

Override with GT7_CONFIG_DIR. Precedence for the PS5 IP at startup:
  GT7_IP env var  >  config file  >  none (synthetic demo).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def config_dir() -> Path:
    override = os.getenv("GT7_CONFIG_DIR")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "GT7RaceEngineer"
    if os.name == "nt":
        base = os.getenv("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        return Path(base) / "GT7RaceEngineer"
    base = os.getenv("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "gt7-race-engineer"


def config_path() -> Path:
    return config_dir() / "config.json"


def load() -> dict[str, Any]:
    try:
        return json.loads(config_path().read_text())
    except Exception:
        return {}


def save(updates: dict[str, Any]) -> dict[str, Any]:
    """Merge updates into the stored config and write it back atomically."""
    cfg = load()
    cfg.update({k: v for k, v in updates.items() if v is not None})
    # allow explicit clearing with empty string
    for k, v in updates.items():
        if v == "":
            cfg.pop(k, None)
    d = config_dir()
    d.mkdir(parents=True, exist_ok=True)
    tmp = config_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2))
    tmp.replace(config_path())
    return cfg


def get_gt7_ip() -> str:
    """Resolved PS5 IP using the documented precedence (env > file > '')."""
    return os.getenv("GT7_IP") or load().get("gt7_ip", "") or ""
