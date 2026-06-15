"""Generate platform icons from app/static/icon-512.png.

  Windows: packaging/icon.ico   (needs Pillow)
  macOS:   packaging/icon.icns  (needs the system `iconutil`, macOS only)

Run from the repo root: python packaging/make_icons.py
Safe to run anywhere — it skips what the platform can't build.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "app" / "static" / "icon-512.png"
OUT = ROOT / "packaging"


def make_ico() -> None:
    try:
        from PIL import Image
    except ImportError:
        print("Pillow not installed — skipping .ico (pip install pillow)")
        return
    img = Image.open(SRC)
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    img.save(OUT / "icon.ico", sizes=sizes)
    print("wrote", OUT / "icon.ico")


def make_icns() -> None:
    if sys.platform != "darwin" or not shutil.which("iconutil"):
        print("not macOS / no iconutil — skipping .icns")
        return
    from PIL import Image
    iconset = OUT / "icon.iconset"
    iconset.mkdir(exist_ok=True)
    img = Image.open(SRC)
    for s in (16, 32, 64, 128, 256, 512):
        img.resize((s, s)).save(iconset / f"icon_{s}x{s}.png")
        img.resize((min(1024, s * 2),) * 2).save(iconset / f"icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o",
                    str(OUT / "icon.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote", OUT / "icon.icns")


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    make_ico()
    make_icns()
