"""Generate parity vectors for the Flutter/Dart port.

The Dart core must produce the SAME numbers as this Python reference. This
script makes that testable: it runs the real Python implementation and dumps
input→expected-output pairs as JSON, which `flutter/tool/parity/run_parity.dart`
replays against the Dart port (locally and in CI).

Five vector families:
  salsa20   — raw keystream + the GT7 nonce/IV scheme (key, iv1, cipher, plain)
  packets   — built+encrypted GT7 packets with expected parsed fields; every
              expected value comes from gt7dashboard's own salsa20_dec+GTData,
              so the Dart parser is tested against the reference decoder
  engineer  — deterministic synthetic sessions (race / test_run / time_trial /
              baseline): serialized telemetry+laps inputs → snapshot outputs
  callouts  — scripted snapshot sequences → fired callout lines
  misc      — schemas payload + fmt_ms/fmt_clock cases

Self-checking: the from-scratch Salsa20 here is asserted against pycryptodome,
and every built packet is asserted to round-trip through the real decoder
before anything is written. Run from the repo root:

    python tools/gen_parity_vectors.py
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from Crypto.Cipher import Salsa20 as PycaSalsa20  # reference for self-check

from gt7dashboard.gt7communication import salsa20_dec, GTData
from app.model import TelemetryFrame, LapRecord, fmt_ms, fmt_clock
from app.events import schemas_payload, EventConfig
from app.engineer import SessionEngineer
from app.callouts import CalloutEngine
from app.providers import SyntheticProvider

OUT = Path(__file__).resolve().parent.parent / "flutter" / "tool" / "parity" / "vectors"
GT7_KEY = b"Simulator Interface Packet GT7 ver 0.0"[:32]
MAGIC = 0x47375330
PKT = 296


# ---------------------------------------------------------------- salsa20
# From-scratch implementation (djb spec). This exact structure is what the
# Dart port transliterates, so proving THIS against pycryptodome de-risks it.

def _rotl(x: int, n: int) -> int:
    x &= 0xFFFFFFFF
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def _quarter(s, a, b, c, d):
    s[b] ^= _rotl(s[a] + s[d], 7)
    s[c] ^= _rotl(s[b] + s[a], 9)
    s[d] ^= _rotl(s[c] + s[b], 13)
    s[a] ^= _rotl(s[d] + s[c], 18)


def salsa20_block(key32: bytes, nonce8: bytes, counter: int) -> bytes:
    k = struct.unpack("<8I", key32)
    n = struct.unpack("<2I", nonce8)
    c0, c1 = counter & 0xFFFFFFFF, (counter >> 32) & 0xFFFFFFFF
    SIG = (0x61707865, 0x3320646E, 0x79622D32, 0x6B206574)  # "expand 32-byte k"
    init = [SIG[0], k[0], k[1], k[2], k[3], SIG[1], n[0], n[1],
            c0, c1, SIG[2], k[4], k[5], k[6], k[7], SIG[3]]
    s = list(init)
    for _ in range(10):  # 20 rounds = 10 double-rounds
        # column round
        _quarter(s, 0, 4, 8, 12)
        _quarter(s, 5, 9, 13, 1)
        _quarter(s, 10, 14, 2, 6)
        _quarter(s, 15, 3, 7, 11)
        # row round
        _quarter(s, 0, 1, 2, 3)
        _quarter(s, 5, 6, 7, 4)
        _quarter(s, 10, 11, 8, 9)
        _quarter(s, 15, 12, 13, 14)
    return struct.pack("<16I", *((a + b) & 0xFFFFFFFF for a, b in zip(s, init)))


def salsa20_xor(key32: bytes, nonce8: bytes, data: bytes) -> bytes:
    out = bytearray(len(data))
    for blk in range((len(data) + 63) // 64):
        ks = salsa20_block(key32, nonce8, blk)
        for i in range(blk * 64, min(len(data), blk * 64 + 64)):
            out[i] = data[i] ^ ks[i - blk * 64]
    return bytes(out)


def gt7_nonce(iv1: int) -> bytes:
    iv2 = (iv1 ^ 0xDEADBEAF) & 0xFFFFFFFF
    return iv2.to_bytes(4, "little") + iv1.to_bytes(4, "little")


def gt7_encrypt(plain: bytes, iv1: int) -> bytes:
    """Inverse of salsa20_dec: XOR with keystream, then stamp the IV at 0x40
    in the CIPHERTEXT (the decryptor reads it from there pre-decrypt)."""
    cipher = bytearray(salsa20_xor(GT7_KEY, gt7_nonce(iv1), plain))
    cipher[0x40:0x44] = iv1.to_bytes(4, "little")
    return bytes(cipher)


def self_check_salsa() -> None:
    import os
    for _ in range(6):
        key, nonce = os.urandom(32), os.urandom(8)
        data = os.urandom(300)
        ref = PycaSalsa20.new(key, nonce).encrypt(data)
        assert salsa20_xor(key, nonce, data) == ref, "from-scratch Salsa20 != pycryptodome"
    print("self-check: Salsa20 matches pycryptodome")


# ---------------------------------------------------------------- packets

def build_packet(*, in_race=True, paused=False, current_lap=12, total_laps=0,
                 best_ms=94979, last_ms=95234, fuel=42.5, capacity=80.0,
                 speed_kmh=231.4, throttle_pct=100.0, brake_pct=0.0,
                 gear=4, suggested=4, car_id=3298, package_id=123456,
                 pos_x=412.25, pos_y=2.5, pos_z=-187.75,
                 tt_fl=92.5, tt_fr=96.25, tt_rl=88.0, tt_rr=90.5,
                 cur_pos=3, total_pos=16, rpm=7450.0) -> bytes:
    """Write the fields GTData reads at their documented offsets."""
    b = bytearray(PKT)
    def f32(off, v): b[off:off + 4] = struct.pack("<f", v)
    def i32(off, v): b[off:off + 4] = struct.pack("<i", v)
    def i16(off, v): b[off:off + 2] = struct.pack("<h", v)
    def u8(off, v): b[off] = v & 0xFF

    i32(0x00, MAGIC)
    f32(0x04, pos_x); f32(0x08, pos_y); f32(0x0C, pos_z)
    f32(0x3C, rpm)
    f32(0x44, fuel); f32(0x48, capacity)
    f32(0x4C, speed_kmh / 3.6)                      # stored as m/s
    f32(0x60, tt_fl); f32(0x64, tt_fr); f32(0x68, tt_rl); f32(0x6C, tt_rr)
    i32(0x70, package_id)
    i16(0x74, current_lap); i16(0x76, total_laps)
    i32(0x78, best_ms); i32(0x7C, last_ms)
    i32(0x80, 5_400_000)                            # time-of-day ms (unused by frame)
    i16(0x84, cur_pos); i16(0x86, total_pos)
    u8(0x8E, (1 if in_race else 0) | (2 if paused else 0))
    u8(0x90, (gear & 0x0F) | ((suggested & 0x0F) << 4))
    u8(0x91, int(round(throttle_pct * 2.55)))
    u8(0x92, int(round(brake_pct * 2.55)))
    i32(0x124, car_id)
    return bytes(b)


def expected_fields_via_reference(cipher: bytes) -> dict:
    """Ground truth: run the REAL decoder and read what it parsed."""
    plain = salsa20_dec(cipher)
    assert len(plain) > 0, "reference decoder rejected a built packet"
    d = GTData(plain)
    return {
        "package_id": d.package_id, "current_lap": d.current_lap,
        "total_laps": d.total_laps, "best_lap_ms": d.best_lap,
        "last_lap_ms": d.last_lap, "current_fuel": d.current_fuel,
        "fuel_capacity": d.fuel_capacity, "car_speed_kmh": d.car_speed,
        "throttle": d.throttle, "brake": d.brake,
        "in_race": d.in_race, "is_paused": d.is_paused,
        "current_gear": d.current_gear, "suggested_gear": d.suggested_gear,
        "car_id": d.car_id, "position_x": d.position_x,
        "position_y": d.position_y, "position_z": d.position_z,
        "tyre_temp_fl": d.tyre_temp_FL, "tyre_temp_fr": d.tyre_temp_FR,
        "tyre_temp_rl": d.tyre_temp_rl, "tyre_temp_rr": d.tyre_temp_rr,
        "current_position": d.current_position, "total_positions": d.total_positions,
    }


def gen_packets() -> dict:
    cases = []
    specs = [
        dict(),                                               # racing default
        dict(in_race=False, current_lap=0, fuel=80.0, speed_kmh=0.0,
             throttle_pct=0.0, package_id=7),                 # in menu
        dict(paused=True, brake_pct=42.0, gear=2, suggested=3,
             current_lap=1, best_ms=-1, last_ms=-1),          # paused, no laps yet
        dict(current_lap=31, total_laps=0, fuel=3.2, speed_kmh=288.7,
             best_ms=93211, last_ms=93444, cur_pos=1, total_pos=12,
             pos_x=-1023.5, pos_z=755.125, tt_fl=109.5, tt_rr=112.25),
    ]
    for i, sp in enumerate(specs):
        plain = build_packet(**sp)
        iv1 = (0x1357_9BDF * (i + 1)) & 0xFFFFFFFF
        cipher = gt7_encrypt(plain, iv1)
        cases.append({"iv1": iv1, "cipher_hex": cipher.hex(),
                      "fields": expected_fields_via_reference(cipher)})
    # negative: corrupt one ciphertext byte (not the IV) -> magic check fails
    bad = bytearray(bytes.fromhex(cases[0]["cipher_hex"])); bad[0] ^= 0xFF
    assert len(salsa20_dec(bytes(bad))) == 0
    return {"cases": cases, "reject_hex": bytes(bad).hex(),
            "key_hex": GT7_KEY.hex(), "magic": MAGIC}


def gen_salsa() -> dict:
    key = GT7_KEY
    raw = []
    for nonce in (b"\x00" * 8, b"\x01\x02\x03\x04\x05\x06\x07\x08",
                  gt7_nonce(0xCAFEBABE)):
        ks = salsa20_xor(key, nonce, b"\x00" * 160)            # 2.5 blocks
        raw.append({"nonce_hex": nonce.hex(), "keystream_hex": ks.hex()})
    return {"key_hex": key.hex(), "raw": raw}


# ---------------------------------------------------------------- engineer

def tel_dict(t: TelemetryFrame) -> dict:
    return {k: getattr(t, k) for k in (
        "connected", "in_race", "is_paused", "current_lap", "total_laps",
        "last_lap_ms", "best_lap_ms", "current_fuel", "fuel_capacity",
        "car_speed", "throttle", "brake", "tyre_temp_fl", "tyre_temp_fr",
        "tyre_temp_rl", "tyre_temp_rr")}


def lap_dict(lp: LapRecord) -> dict:
    return {"number": lp.number, "lap_finish_time_ms": lp.lap_finish_time_ms,
            "fuel_consumed": lp.fuel_consumed, "fuel_at_end": lp.fuel_at_end,
            "stint_lap": lp.stint_lap, "is_outlier": lp.is_outlier}


class _Ref:
    def __init__(self, ms): self.best_lap_ms = ms


def gen_engineer() -> dict:
    sessions = []
    for ev_type, values, ref, steps, dt in [
        ("race", {"race_minutes": 24, "mandatory_stops": 1,
                  "refuel_rate_lps": 9.0, "pit_lane_loss_s": 22.0}, None, 760, 2.0),
        ("test_run", {"tire_compound": "RM", "target_stint_laps": 8}, None, 420, 2.0),
        ("time_trial", {"tire_compound": "RS"}, _Ref(94500), 240, 2.0),
        ("baseline", {"track_name": "Parity Ring"}, None, 120, 2.0),
    ]:
        prov = SyntheticProvider(seed=7)
        ev = EventConfig.build(ev_type, **values)
        eng = SessionEngineer(ev, reference=ref)
        prov.add_pit_listener(eng.notify_pit)
        clock, samples = 0.0, []
        for i in range(steps):
            prov.step(dt)
            clock += dt
            if i % 10 == 0:
                snap = eng.snapshot(prov.telemetry, prov.laps, now=clock)
                samples.append({
                    "now": clock,
                    "tel": tel_dict(prov.telemetry),
                    "laps": [lap_dict(lp) for lp in prov.laps],
                    "stops_made": eng._stops_made,
                    "expect": snap,
                })
        sessions.append({"event_type": ev_type, "values": values,
                         "reference_best_ms": ref.best_lap_ms if ref else None,
                         "samples": samples})
    return {"sessions": sessions}


# ---------------------------------------------------------------- callouts

def gen_callouts() -> dict:
    base = {"in_race": True, "event_type": "race", "current_lap": 0}
    script = [
        (0.0, dict(base)),                                            # greeting
        (10.0, dict(base, current_lap=3, fuel_laps_left=14.0,
                    fuel_balance_laps=1.2)),                          # fuel_update (lap%3)
        (20.0, dict(base, current_lap=4, fuel_laps_left=1.4,
                    stops_left=1, pit_by_lap=4)),                     # box
        (40.0, dict(base, current_lap=5, stops_left=0,
                    fuel_balance_laps=-0.5, fuel_save_target_l=2.9)),  # fuel critical
        (90.0, dict(base, current_lap=6, stops_left=0,
                    fuel_balance_laps=-0.1)),                          # fuel save
        (160.0, dict(base, current_lap=7, deg_per_lap_s=0.21)),        # deg cliff
        (220.0, dict(base, current_lap=8,
                     tyre_temps={"fl": 99.0, "fr": 113.5, "rl": 96.0, "rr": 108.0})),  # hot tyre
        (240.0, dict(base, current_lap=9, fuel_laps_left=8.0,
                     fuel_balance_laps=0.4)),                          # fuel_update (lap%3)
        (260.0, dict(base, current_lap=10, laps_left_race=2)),         # two to go
        (270.0, {"in_race": False, "event_type": "race"}),             # silent
    ]
    eng = CalloutEngine()
    fired = []
    for now, snap in script:
        for c in eng.ingest(snap, now):
            fired.append({"at": now, "category": c.category,
                          "text": c.text, "priority": c.priority})
    # time-trial pace lines
    tt_eng = CalloutEngine()
    tt_script = [
        (0.0, {"in_race": True, "event_type": "time_trial"}),
        (5.0, {"in_race": True, "event_type": "time_trial", "delta_last_to_ref_s": -0.31}),
        (40.0, {"in_race": True, "event_type": "time_trial", "delta_last_to_ref_s": 0.42}),
    ]
    tt_fired = []
    for now, snap in tt_script:
        for c in tt_eng.ingest(snap, now):
            tt_fired.append({"at": now, "category": c.category,
                             "text": c.text, "priority": c.priority})
    return {"race": {"script": [{"now": n, "snap": s} for n, s in script],
                     "fired": fired},
            "time_trial": {"script": [{"now": n, "snap": s} for n, s in tt_script],
                           "fired": tt_fired}}


# ---------------------------------------------------------------- misc

def gen_misc() -> dict:
    fmt_cases = [{"ms": ms, "out": fmt_ms(ms)} for ms in
                 (None, -1, 0, 999, 1000, 59999, 60000, 65432, 95234,
                  600000, 3599999, 5025678)]
    clock_cases = [{"s": s, "out": fmt_clock(s)} for s in
                   (-5.0, 0.0, 0.4, 59.9, 60.0, 61.0, 599.0, 1432.7, 2400.0)]
    return {"schemas": schemas_payload(), "fmt_ms": fmt_cases,
            "fmt_clock": clock_cases}


# ---------------------------------------------------------------- main

def _lt_dict(t) -> dict:
    return {"x": list(t.x), "z": list(t.z), "speed": list(t.speed),
            "throttle": list(t.throttle), "brake": list(t.brake),
            "t_ms": list(t.t_ms), "label": t.label}


def gen_analysis() -> dict:
    """Deterministic target/reference lap pairs (oval + 2 corners), with the
    expected comparison_traces() output and the robust scalars + delta trace of
    analyze() — the numbers the Get Faster charts, map, and delta line render."""
    import math
    from app.analysis import LapTrace, analyze, comparison_traces

    def make(corner_pen: float, label: str, n: int = 120) -> "LapTrace":
        a, b, base = 420.0, 260.0, 230.0
        xs, zs, spd, tms = [], [], [], []
        t_acc, prev = 0.0, None
        for k in range(n + 1):
            u = k / n
            ang = 2 * math.pi * u
            x, z = a * math.cos(ang), b * math.sin(ang)
            dip = 0.0
            for cu, depth in ((0.25, 120.0), (0.75, 110.0)):
                d = abs(((u - cu + 0.5) % 1.0) - 0.5)
                if d < 0.08:
                    dip = max(dip, (depth + corner_pen) * (1 - d / 0.08))
            s = max(70.0, base - dip)
            if prev is not None:
                t_acc += math.hypot(x - prev[0], z - prev[1]) / (max(20.0, s) / 3.6)
            xs.append(x); zs.append(z); spd.append(s); tms.append(t_acc * 1000.0)
            prev = (x, z)
        thr, brk = [], []
        for i in range(len(spd)):
            ds = spd[min(i + 1, len(spd) - 1)] - spd[max(i - 1, 0)]
            brk.append(max(0.0, min(100.0, -ds * 8)))
            thr.append(100.0 if ds > -1 else 0.0)
        return LapTrace(xs, zs, spd, thr, brk, tms, label=label)

    cases = []
    for pen in (6.0, 3.0):
        tgt, ref = make(pen, "target"), make(0.0, "reference")
        rep = analyze(tgt, ref)
        cases.append({
            "target": _lt_dict(tgt), "reference": _lt_dict(ref),
            "traces": comparison_traces(tgt, ref),
            "analyze_core": {
                "total_delta_s": rep["total_delta_s"],
                "lap_length_m": rep["lap_length_m"],
                "delta_trace": rep["delta_trace"],
            },
        })
    return {"cases": cases}


def main() -> None:
    self_check_salsa()
    OUT.mkdir(parents=True, exist_ok=True)
    files = {
        "salsa20.json": gen_salsa(),
        "packets.json": gen_packets(),
        "engineer.json": gen_engineer(),
        "callouts.json": gen_callouts(),
        "misc.json": gen_misc(),
        "analysis.json": gen_analysis(),
    }
    total = 0
    for name, payload in files.items():
        p = OUT / name
        p.write_text(json.dumps(payload, indent=1))
        total += p.stat().st_size
        print(f"wrote {p.relative_to(OUT.parent.parent.parent)} ({p.stat().st_size // 1024} KB)")
    print(f"total vectors: {total // 1024} KB")


if __name__ == "__main__":
    main()