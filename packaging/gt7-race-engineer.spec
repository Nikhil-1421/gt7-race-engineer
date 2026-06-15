# PyInstaller spec — builds the double-clickable GT7 Race Engineer.
#
#   macOS:    pyinstaller packaging/gt7-race-engineer.spec   -> dist/GT7 Race Engineer.app
#   Windows:  pyinstaller packaging\gt7-race-engineer.spec   -> dist/GT7RaceEngineer/
#   Linux:    same command (used by CI smoke tests)           -> dist/GT7RaceEngineer/
#
# PyInstaller cannot cross-compile: each OS builds its own binary
# (.github/workflows/build-desktop.yml does both on tag pushes).
import os
import sys
from pathlib import Path

ROOT = Path(SPECPATH).parent          # repo root (spec lives in packaging/)

# Modules imported lazily at runtime — static analysis can't see these, so
# they must be declared or the binary dies on first use.
hidden = [
    # lazy app modules (server/providers import these inside functions)
    "app.discovery", "app.adapters", "app.local_voice", "app.tts", "app.stt",
    "app.discord_engineer",
    # lazy capture chain (RealProvider -> gt7dashboard)
    "gt7dashboard.gt7communication", "gt7dashboard.gt7lap", "gt7dashboard.gt7helper",
    # uvicorn's dynamic protocol/loop selection
    "uvicorn.logging", "uvicorn.loops", "uvicorn.loops.auto",
    "uvicorn.protocols", "uvicorn.protocols.http", "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl", "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto", "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.lifespan", "uvicorn.lifespan.on", "websockets",
    # optional voice stack (only used when configured; cheap to declare)
    "discord", "nacl",
]

a = Analysis(
    [str(ROOT / "app" / "desktop.py")],
    pathex=[str(ROOT)],
    datas=[(str(ROOT / "app" / "static"), "app/static")],
    hiddenimports=hidden,
    excludes=["bokeh", "matplotlib", "tkinter.test", "pytest"],
    noarchive=False,
)
pyz = PYZ(a.pure)

is_mac = sys.platform == "darwin"
is_win = sys.platform == "win32"
icon = None
if is_win and (ROOT / "packaging" / "icon.ico").exists():
    icon = str(ROOT / "packaging" / "icon.ico")
if is_mac and (ROOT / "packaging" / "icon.icns").exists():
    icon = str(ROOT / "packaging" / "icon.icns")

# windowed on the desktop OSes; console on Linux/CI (override: PYI_CONSOLE=1)
console = (not (is_mac or is_win)) or os.environ.get("PYI_CONSOLE") == "1"

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="GT7RaceEngineer",
    console=console,
    icon=icon,
)
coll = COLLECT(exe, a.binaries, a.datas, name="GT7RaceEngineer")

if is_mac:
    app = BUNDLE(
        coll,
        name="GT7 Race Engineer.app",
        icon=icon,
        bundle_identifier="io.gt7raceengineer.desktop",
        info_plist={
            "NSHighResolutionCapable": True,
            "LSApplicationCategoryType": "public.app-category.sports",
            "NSHumanReadableCopyright": "Community tool for use with Gran Turismo 7. "
                                        "Not affiliated with Sony or Polyphony Digital.",
        },
    )
