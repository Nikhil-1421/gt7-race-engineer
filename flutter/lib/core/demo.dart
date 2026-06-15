/// Synthetic demo provider — lets the app run with no console, mirroring the
/// Python repo's demo mode. Deterministic, deliberately simple; NOT part of
/// the parity surface (parity vectors carry the Python-generated inputs).
library;

import 'dart:math';

import 'analysis.dart';
import 'model.dart';

class DemoProvider {
  final double baseLapS;
  final double degSPerLap;
  final double fuelPerLap;
  final double pitLossS;
  final Random _rng = Random(7);

  TelemetryFrame telemetry;
  final List<LapRecord> laps = [];
  final List<LapTrace> lapTraces = [];
  void Function()? onPit;

  double _lapElapsed = 0;
  int _stintLap = 1;
  late double _lapTarget;
  final double _tyreBase = 75.0;

  DemoProvider(
      {this.baseLapS = 95.0,
      this.degSPerLap = 0.07,
      this.fuelPerLap = 3.2,
      this.pitLossS = 22.0})
      : telemetry = const TelemetryFrame(
            connected: true,
            inRace: true,
            currentLap: 1,
            currentFuel: 65.0,
            fuelCapacity: 80.0,
            carSpeed: 180.0,
            throttle: 100.0) {
    _lapTarget = _lapTime(1);
  }

  double _lapTime(int stintLap) =>
      baseLapS + degSPerLap * (stintLap - 1) + (_rng.nextDouble() * 0.4 - 0.15);

  void step(double dt) {
    var t = telemetry;
    if (!t.inRace) return;
    _lapElapsed += dt;
    final burn = fuelPerLap * (dt / _lapTarget);
    var fuel = (t.currentFuel - burn).clamp(0.0, t.fuelCapacity);
    var fl = _tyreBase + min(18, _stintLap * 1.6) + _rng.nextDouble() * 2 - 1;

    var lap = t.currentLap;
    var lastMs = t.lastLapMs, bestMs = t.bestLapMs;
    if (_lapElapsed >= _lapTarget) {
      final lapMs = (_lapTarget * 1000).toInt();
      final pitNow = fuel < fuelPerLap * 1.3;
      var consumed = fuelPerLap + _rng.nextDouble() * 0.1 - 0.05;
      var outlier = false;
      if (pitNow) {
        fuel = t.fuelCapacity.clamp(0.0, 80.0);
        onPit?.call();
        _stintLap = 0;
        outlier = true;
      }
      laps.add(LapRecord(
          number: lap,
          lapFinishTimeMs: lapMs + (pitNow ? (pitLossS * 1000).toInt() : 0),
          fuelConsumed: outlier ? 0 : consumed,
          fuelAtEnd: fuel,
          stintLap: outlier ? 0 : _stintLap,
          isOutlier: outlier));
      _emitTrace(_stintLap, lap);
      lastMs = lapMs;
      if (bestMs <= 0 || lapMs < bestMs) bestMs = lapMs;
      lap += 1;
      _stintLap += 1;
      _lapElapsed = 0;
      _lapTarget = _lapTime(_stintLap);
    }

    final frac = _lapTarget > 0 ? _lapElapsed / _lapTarget : 0.0;
    double dip = 0;
    for (final c in const [
      [0.25, 120.0],
      [0.75, 110.0]
    ]) {
      final dd = (((frac - c[0] + 0.5) % 1.0) - 0.5).abs();
      if (dd < 0.08) dip = max(dip, c[1] * (1 - dd / 0.08));
    }
    final spd = max(70.0, 230.0 - dip);
    final thr = dip < 30 ? 100.0 : max(0.0, 60.0 - dip);
    final brk = dip > 30 ? min(100.0, dip) : 0.0;

    telemetry = TelemetryFrame(
      connected: true,
      inRace: true,
      currentLap: lap,
      lastLapMs: lastMs,
      bestLapMs: bestMs,
      currentFuel: fuel,
      fuelCapacity: t.fuelCapacity,
      carSpeed: spd,
      throttle: thr,
      brake: brk,
      tyreTempFl: fl,
      tyreTempFr: fl + 2 + _rng.nextDouble() * 3,
      tyreTempRl: _tyreBase + min(15, _stintLap * 1.3),
      tyreTempRr: _tyreBase + min(15, _stintLap * 1.3) + 1.5,
      rpm: 3500 + (spd % 40) / 40 * 4500,
      gear: max(1, min(6, (spd ~/ 40) + 1)),
      boost: thr > 80 ? 0.6 : 0.0,
      oilTemp: 104,
      waterTemp: 92,
    );
  }

  // Synthesize a realistic per-tick trace (oval + 2 corners) for this lap,
  // mirroring SyntheticProvider._emit_trace so the charts/map have data in demo.
  void _emitTrace(int stintLap, int lapNum) {
    const n = 160;
    const a = 420.0, b = 260.0, base = 230.0;
    final cornerPen =
        min(9.0, (stintLap - 1) * 0.6) + (_rng.nextDouble() - 0.5);
    final xs = <double>[], zs = <double>[], spd = <double>[], tms = <double>[];
    double tAcc = 0;
    double? px, pz;
    for (var k = 0; k <= n; k++) {
      final u = k / n;
      final ang = 2 * pi * u;
      final x = a * cos(ang), z = b * sin(ang);
      double dip = 0;
      for (final c in const [
        [0.25, 120.0],
        [0.75, 110.0]
      ]) {
        final d = (((u - c[0] + 0.5) % 1.0) - 0.5).abs();
        if (d < 0.08) dip = max(dip, (c[1] + cornerPen) * (1 - d / 0.08));
      }
      final s = max(70.0, base - dip);
      if (px != null) {
        tAcc += sqrt((x - px) * (x - px) + (z - pz!) * (z - pz)) /
            (max(20.0, s) / 3.6);
      }
      xs.add(x);
      zs.add(z);
      spd.add(s);
      tms.add(tAcc * 1000.0);
      px = x;
      pz = z;
    }
    final thr = <double>[], brk = <double>[];
    for (var i = 0; i < spd.length; i++) {
      final ds = spd[min(i + 1, spd.length - 1)] - spd[max(i - 1, 0)];
      brk.add(max(0.0, min(100.0, -ds * 8)));
      thr.add(ds > -1 ? 100.0 : 0.0);
    }
    lapTraces.add(LapTrace(
        x: xs,
        z: zs,
        speed: spd,
        throttle: thr,
        brake: brk,
        tMs: tms,
        label: 'lap$lapNum'));
  }
}