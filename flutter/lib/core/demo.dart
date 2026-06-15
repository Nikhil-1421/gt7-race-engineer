/// Synthetic demo provider — lets the app run with no console, mirroring the
/// Python repo's demo mode. Deterministic, deliberately simple; NOT part of
/// the parity surface (parity vectors carry the Python-generated inputs).
library;

import 'dart:math';

import 'model.dart';

class DemoProvider {
  final double baseLapS;
  final double degSPerLap;
  final double fuelPerLap;
  final double pitLossS;
  final Random _rng = Random(7);

  TelemetryFrame telemetry;
  final List<LapRecord> laps = [];
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
      lastMs = lapMs;
      if (bestMs <= 0 || lapMs < bestMs) bestMs = lapMs;
      lap += 1;
      _stintLap += 1;
      _lapElapsed = 0;
      _lapTarget = _lapTime(_stintLap);
    }

    telemetry = TelemetryFrame(
      connected: true,
      inRace: true,
      currentLap: lap,
      lastLapMs: lastMs,
      bestLapMs: bestMs,
      currentFuel: fuel,
      fuelCapacity: t.fuelCapacity,
      carSpeed: 150 + _rng.nextDouble() * 100,
      throttle: t.throttle,
      tyreTempFl: fl,
      tyreTempFr: fl + 2 + _rng.nextDouble() * 3,
      tyreTempRl: _tyreBase + min(15, _stintLap * 1.3),
      tyreTempRr: _tyreBase + min(15, _stintLap * 1.3) + 1.5,
    );
  }
}
