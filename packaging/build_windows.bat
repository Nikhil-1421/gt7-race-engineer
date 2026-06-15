@echo off
REM Build GT7RaceEngineer for Windows. Run from the repo root:
REM   packaging\build_windows.bat
python -m pip install -r requirements.txt pyinstaller pillow || exit /b 1
python packaging\make_icons.py || exit /b 1
pyinstaller --clean --noconfirm packaging\gt7-race-engineer.spec || exit /b 1
powershell -Command "Compress-Archive -Force -Path 'dist/GT7RaceEngineer' -DestinationPath 'dist/GT7RaceEngineer-Windows.zip'"
echo Built dist\GT7RaceEngineer\GT7RaceEngineer.exe  (zip: dist\GT7RaceEngineer-Windows.zip)
echo Unsigned build: SmartScreen will warn on first run - More info ^> Run anyway.
