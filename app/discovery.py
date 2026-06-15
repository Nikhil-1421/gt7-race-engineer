"""PS5 auto-discovery — find the console without the user hunting for an IP.

How it works: GT7 replies with encrypted telemetry on UDP 33740 to whoever
sends the one-byte 'A' heartbeat to UDP 33739. We don't need to decrypt
anything to *find* the console — any reply's source address IS the PS5.

Strategy (all stdlib):
  1. Broadcast the heartbeat to 255.255.255.255 and each interface's
     /24 broadcast address (x.y.z.255).
  2. If nothing answers quickly, unicast-sweep the local /24 (254 cheap
     UDP sends) — some routers/APs filter broadcast between wifi/wired.
  3. First packet received on 33740 wins; return its source IP.

Requirements: the console is on, GT7 is running (any screen after the
title works), and this machine + PS5 share a LAN. The receive port 33740
must be free, so discovery runs while live capture is stopped — the
server endpoint handles that ordering.
"""
from __future__ import annotations

import socket
import time
from dataclasses import dataclass
from typing import Iterable, List, Optional

HEARTBEAT = b"A"
SEND_PORT = 33739
RECV_PORT = 33740


@dataclass
class DiscoveryResult:
    ip: Optional[str] = None
    error: Optional[str] = None          # "port_busy" | "not_found"
    tried_broadcast: bool = False
    tried_sweep: bool = False
    elapsed_s: float = 0.0


def _local_ipv4s() -> List[str]:
    """Best-effort list of this machine's LAN IPv4 addresses."""
    ips: set[str] = set()
    try:
        # UDP connect to a public address never sends a packet but binds a
        # source address — the classic trick for "what's my LAN IP".
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    return [ip for ip in ips if not ip.startswith("127.")]


def _broadcast_targets() -> List[str]:
    targets = ["255.255.255.255"]
    for ip in _local_ipv4s():
        parts = ip.split(".")
        if len(parts) == 4:
            targets.append(".".join(parts[:3] + ["255"]))
    return list(dict.fromkeys(targets))


def _sweep_targets() -> List[str]:
    out: List[str] = []
    for ip in _local_ipv4s():
        a, b, c, d = ip.split(".")
        out.extend(f"{a}.{b}.{c}.{h}" for h in range(1, 255)
                   if f"{a}.{b}.{c}.{h}" != ip)
    return out


def discover(timeout_s: float = 6.0,
             sweep: bool = True,
             extra_targets: Optional[Iterable[str]] = None) -> DiscoveryResult:
    """Find the PS5. Blocking (run in a thread from async code).

    extra_targets: additional unicast addresses to probe immediately —
    used by tests (e.g. a fake console on 127.0.0.1) and power users.
    """
    res = DiscoveryResult()
    start = time.monotonic()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.bind(("0.0.0.0", RECV_PORT))
    except OSError:
        sock.close()
        res.error = "port_busy"
        return res

    def send_to(addrs: Iterable[str]):
        for a in addrs:
            try:
                sock.sendto(HEARTBEAT, (a, SEND_PORT))
            except OSError:
                pass

    try:
        sock.settimeout(0.4)
        broadcast = _broadcast_targets()
        extras = list(extra_targets or [])
        swept = False
        next_hb = 0.0
        while (elapsed := time.monotonic() - start) < timeout_s:
            if elapsed >= next_hb:                       # re-heartbeat every ~1.2s
                send_to(broadcast)
                send_to(extras)
                res.tried_broadcast = True
                next_hb = elapsed + 1.2
            if sweep and not swept and elapsed > 1.5:    # broadcast got nothing -> sweep
                send_to(_sweep_targets())
                res.tried_sweep = swept = True
            try:
                _, addr = sock.recvfrom(4096)
                res.ip = addr[0]
                res.elapsed_s = round(time.monotonic() - start, 2)
                return res
            except socket.timeout:
                continue
    finally:
        sock.close()

    res.error = "not_found"
    res.elapsed_s = round(time.monotonic() - start, 2)
    return res
