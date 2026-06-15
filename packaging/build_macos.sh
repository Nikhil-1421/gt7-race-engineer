#!/usr/bin/env bash
# Build "GT7 Race Engineer.app" on macOS. Run from the repo root:
#   bash packaging/build_macos.sh
set -euo pipefail
python3 -m pip install -r requirements.txt pyinstaller pillow
python3 packaging/make_icons.py
pyinstaller --clean --noconfirm packaging/gt7-race-engineer.spec
cd dist && ditto -c -k --sequesterRsrc --keepParent "GT7 Race Engineer.app" GT7RaceEngineer-macOS.zip
echo "Built dist/GT7 Race Engineer.app  (zip: dist/GT7RaceEngineer-macOS.zip)"
echo "Unsigned build: first launch is right-click -> Open (see INSTALL.md)."
