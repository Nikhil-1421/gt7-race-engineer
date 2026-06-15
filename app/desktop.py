"""GT7 Race Engineer — desktop launcher (the double-clickable app).

This is the entry point the macOS .app and Windows .exe run:
  - starts the FastAPI/uvicorn server in a background thread
  - opens the dashboard in the default browser once it's up
  - shows a small status window: connection state, PS5 IP, Find-my-PS5,
    Open Dashboard, Quit
  - logs to a file (windowed builds have no console)

Headless use (CI, servers, `--no-ui`, or no display): runs the server in the
foreground and still auto-opens the browser when a display exists.
"""
from __future__ import annotations

import logging
import os
import socket
import sys
import threading
import time
import webbrowser
from pathlib import Path

# Make `python app/desktop.py` work as well as `python -m app.desktop`
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as user_config  # noqa: E402

PORT = int(os.getenv("PORT", 8000))
URL = f"http://127.0.0.1:{PORT}"
log = logging.getLogger("desktop")


def _setup_logging() -> Path:
    logdir = user_config.config_dir() / "logs"
    logdir.mkdir(parents=True, exist_ok=True)
    logfile = logdir / "engineer.log"
    handlers: list[logging.Handler] = [logging.FileHandler(logfile, encoding="utf-8")]
    if sys.stderr is not None:                      # windowed builds: stderr is None
        handlers.append(logging.StreamHandler())
    logging.basicConfig(level=logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    return logfile


def _start_server() -> threading.Thread:
    def run():
        import uvicorn
        from app.server import app  # noqa: WPS433 (import in thread keeps startup snappy)
        uvicorn.run(app, host=os.getenv("HOST", "0.0.0.0"), port=PORT,
                    log_config=None, access_log=False)
    t = threading.Thread(target=run, daemon=True, name="server")
    t.start()
    return t


def _wait_up(timeout: float = 20.0) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def _lan_url() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return f"http://{ip}:{PORT}"
    except OSError:
        return URL


# ----------------------------------------------------------------- UI


def _run_window() -> None:
    import tkinter as tk
    from app.server import state                    # in-process: live truth

    root = tk.Tk()
    root.title("GT7 Race Engineer")
    root.geometry("420x250")
    root.resizable(False, False)
    BG, FG, DIM, ACC = "#0b0d11", "#e8eaf0", "#8b93a7", "#34d399"
    root.configure(bg=BG)

    def lbl(text, **kw):
        return tk.Label(root, text=text, bg=BG, fg=kw.pop("fg", FG),
                        font=kw.pop("font", ("Helvetica", 12)), **kw)

    lbl("GT7 Race Engineer", font=("Helvetica", 16, "bold")).pack(pady=(14, 2))
    status = lbl("starting…", fg=DIM); status.pack()
    console = lbl("", fg=DIM); console.pack(pady=(2, 0))
    phone = lbl(f"Phone/tablet: {_lan_url()}  (Add to Home Screen)",
                fg=DIM, font=("Helvetica", 10))
    phone.pack(pady=(4, 8))

    btns = tk.Frame(root, bg=BG); btns.pack(pady=4)

    def mkbtn(text, cmd, col=0):
        b = tk.Button(btns, text=text, command=cmd, padx=10, pady=4,
                      highlightbackground=BG)
        b.grid(row=0, column=col, padx=5)
        return b

    mkbtn("Open Dashboard", lambda: webbrowser.open(URL), 0)
    find_btn = mkbtn("Find my PS5", lambda: _discover(), 1)
    mkbtn("Quit", lambda: (root.destroy(), os._exit(0)), 2)
    hint = lbl("", fg=DIM, font=("Helvetica", 10)); hint.pack(pady=(6, 0))

    def _discover():
        find_btn.config(state="disabled", text="Searching…")
        hint.config(text="Make sure GT7 is open on the console.")

        def work():
            from app.discovery import discover
            previous = state.gt7_ip
            if not state._synthetic:
                state.set_gt7_ip("", persist=False)
                time.sleep(0.3)
            res = discover(timeout_s=6.0)
            if res.ip:
                state.set_gt7_ip(res.ip)
                msg = f"Found console at {res.ip} — going live."
            else:
                if previous:
                    state.set_gt7_ip(previous, persist=False)
                msg = ("Nothing answered. Same network? GT7 running? "
                       "You can enter the IP in the dashboard.")
            root.after(0, lambda: (hint.config(text=msg),
                                   find_btn.config(state="normal", text="Find my PS5")))
        threading.Thread(target=work, daemon=True).start()

    def tick():
        snap = state.snapshot or {}
        if state._synthetic:
            console.config(text="No console linked — demo data running", fg=DIM)
        else:
            live = snap.get("connected")
            console.config(text=f"PS5 {state.gt7_ip}: "
                                f"{'telemetry live' if live else 'waiting for telemetry…'}",
                           fg=(ACC if live else DIM))
        status.config(text=f"Server running at {URL}", fg=ACC)
        root.after(700, tick)

    tick()
    root.mainloop()


def main() -> None:
    logfile = _setup_logging()
    log.info("launcher starting; log at %s", logfile)
    _start_server()
    if not _wait_up():
        log.error("server failed to start — see log: %s", logfile)
        if sys.stderr:
            print(f"Server failed to start. Log: {logfile}", file=sys.stderr)
        sys.exit(1)
    log.info("server up at %s", URL)
    webbrowser.open(URL)

    headless = "--no-ui" in sys.argv or os.getenv("GT7_NO_UI") == "1"
    if not headless:
        try:
            _run_window()
            return
        except Exception as e:                      # no display / Tk missing
            log.warning("window unavailable (%s); running headless", e)
    print(f"GT7 Race Engineer running at {URL}  (Ctrl+C to quit)")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
