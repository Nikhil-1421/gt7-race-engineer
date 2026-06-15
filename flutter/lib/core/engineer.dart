/// Event-aware session engineer — faithful port of `app/engineer.py`.
///
/// Every branch, rounding point, and snapshot key mirrors the Python
/// reference; the parity harness replays serialized synthetic sessions
/// through this class and compares full snapshots.
library;

import 'dart:math' as math;

import 'events.dart';
import 'model.dart';

double? _linearSlope(List<double> xs, List<double> ys) {
  final n = xs.length;
  if (n < 2) return null;
  final mx = xs.reduce((a, b) => a + b) / n;
  final my = ys.reduce((a, b) => a + b) / n;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - mx) * (ys[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den == 0 ? null : num / den;
}

/// Duck-typed reference (mirrors TrackBaseline's relevant surface).
class ReferenceLap {
  final int bestLapMs;
  const ReferenceLap(this.bestLapMs);
}

class SessionEngineer {
  final EventConfig event;
  final ReferenceLap? reference;
  late RaceConfig raceCfg;
  double? _raceStartT;
  int stopsMade = 0;

  SessionEngineer(this.event, {this.reference}) {
    raceCfg = event.type == EventType.race
        ? event.raceConfig()
        : const RaceConfig();
  }

  void notifyPit() => stopsMade += 1;

  // ---- shared helpers ----------------------------------------------------
  List<LapRecord> _clean(List<LapRecord> laps) =>
      laps.where((lp) => !lp.isOutlier && lp.lapFinishTimeMs > 0).toList();

  double _elapsed(double now, TelemetryFrame tel) {
    if (tel.inRace && _raceStartT == null) _raceStartT = now;
    return _raceStartT == null ? 0.0 : now - _raceStartT!;
  }

  List<LapRecord> _stintTail(List<LapRecord> clean) {
    final stint = clean.where((lp) => lp.stintLap > 0).toList();
    final tail = <LapRecord>[];
    for (final lp in stint.reversed) {
      if (tail.isNotEmpty && lp.stintLap >= tail.last.stintLap) break;
      tail.add(lp);
    }
    return tail.reversed.toList();
  }

  (Map<String, dynamic>, double?) _paceBlock(
      TelemetryFrame tel, List<LapRecord> recent) {
    double? avgMs;
    if (recent.isNotEmpty) {
      avgMs = recent
              .map((lp) => lp.lapFinishTimeMs)
              .reduce((a, b) => a + b) /
          recent.length;
    }
    int? lastDelta;
    if (tel.lastLapMs > 0 && tel.bestLapMs > 0) {
      lastDelta = tel.lastLapMs - tel.bestLapMs;
    }
    return (
      {
        'current_lap': tel.currentLap,
        'last_lap_str': fmtMs(tel.lastLapMs),
        'best_lap_str': fmtMs(tel.bestLapMs),
        'avg_lap_str':
            (avgMs != null && avgMs != 0) ? fmtMs(avgMs.truncate()) : '--:--.---',
        'last_delta_s':
            lastDelta != null ? roundN(lastDelta / 1000.0, 3) : null,
        'speed_kmh': roundN(tel.carSpeed, 0),
      },
      avgMs
    );
  }

  Map<String, dynamic> _degBlock(List<LapRecord> clean, int? lapsLeft) {
    final tail = _stintTail(clean);
    double? deg;
    int? projMs;
    if (tail.length >= raceCfg.degStintMinLaps) {
      final xs = tail.map((lp) => lp.stintLap.toDouble()).toList();
      final ys = tail.map((lp) => lp.lapFinishTimeMs / 1000.0).toList();
      final slope = _linearSlope(xs, ys);
      if (slope != null) {
        deg = roundN(slope, 3);
        if (lapsLeft != null && lapsLeft != 0) {
          projMs = ((ys.last + slope * lapsLeft) * 1000).truncate();
        }
      }
    }
    final stintLap = tail.isNotEmpty ? tail.last.stintLap + 1 : 0;
    return {
      'stint_lap': stintLap,
      'deg_per_lap_s': deg,
      'proj_end_lap_str': (projMs != null && projMs != 0) ? fmtMs(projMs) : null,
    };
  }

  // ---- mode: RACE ----------------------------------------------------------
  Map<String, dynamic> _race(TelemetryFrame tel, List<LapRecord> clean,
      List<LapRecord> recent, double? avgMs, double now) {
    final cfg = raceCfg;
    final fuelLaps = recent.where((lp) => lp.fuelConsumed > 0).toList();
    double? fpl;
    if (fuelLaps.isNotEmpty) {
      fpl = fuelLaps.map((lp) => lp.fuelConsumed).reduce((a, b) => a + b) /
          fuelLaps.length;
    }

    final elapsed = _elapsed(now, tel);
    final timeLeft = math.max(0.0, cfg.raceSeconds - elapsed);
    final avgS = avgMs != null ? avgMs / 1000.0 : null;
    int? lapsLeft;
    if (avgS != null && avgS > 0) lapsLeft = (timeLeft / avgS).ceil();

    final fuelLapsLeft = fpl != null ? tel.currentFuel / fpl : null;
    double? need;
    if (lapsLeft != null && fpl != null) need = lapsLeft * fpl;
    final balL = need != null ? tel.currentFuel - need : null;
    final balLaps = (balL != null && fpl != null) ? balL / fpl : null;

    double? save;
    if (lapsLeft != null && lapsLeft > 0 && fpl != null) {
      final ach = tel.currentFuel / lapsLeft;
      if (ach < fpl) save = roundN(ach, 2);
    }

    final stopsLeft = math.max(0, cfg.mandatoryStops - stopsMade);
    double? refuelL, refuelT;
    if (need != null && fpl != null) {
      final target = need + cfg.fuelBufferLaps * fpl;
      final add = math.max(
          0.0,
          math.min(target - tel.currentFuel,
              math.max(0.0, tel.fuelCapacity - tel.currentFuel)));
      refuelL = roundN(add, 1);
      refuelT = roundN(add / cfg.refuelRateLps + cfg.pitLaneLossS, 1);
    }
    int? pitBy;
    if (fuelLapsLeft != null) {
      pitBy = tel.currentLap +
          math.max(0, (fuelLapsLeft - cfg.fuelBufferLaps).floor());
    }

    var alert = 'ok', msg = '';
    if (balLaps != null && stopsLeft == 0) {
      if (balLaps < -0.2) {
        alert = 'danger';
        msg = 'SHORT on fuel — save now';
      } else if (balLaps < 0) {
        alert = 'warn';
        msg = 'Marginal fuel — lift & coast';
      }
    }
    if (fuelLapsLeft != null && fuelLapsLeft < 1.5 && stopsLeft > 0) {
      alert = 'warn';
      msg = 'Box this lap — fuel low';
    }

    final out = <String, dynamic>{
      'time_remaining_s': roundN(timeLeft, 1),
      'time_remaining_str': fmtClock(timeLeft),
      'laps_left_race': lapsLeft,
      'fuel_now_l': roundN(tel.currentFuel, 1),
      'fuel_pct': roundN(tel.fuelPct, 1),
      'fuel_per_lap_l': fpl != null ? roundN(fpl, 2) : null,
      'fuel_laps_left':
          fuelLapsLeft != null ? roundN(fuelLapsLeft, 1) : null,
      'fuel_balance_l': balL != null ? roundN(balL, 1) : null,
      'fuel_balance_laps': balLaps != null ? roundN(balLaps, 1) : null,
      'fuel_save_target_l': save,
      'stops_left': stopsLeft,
      'pit_by_lap': pitBy,
      'refuel_for_finish_l': refuelL,
      'refuel_time_s': refuelT,
      'alert': alert,
      'alert_msg': msg,
    };
    out.addAll(_degBlock(clean, lapsLeft));
    out['cards'] = ['fuel', 'pit', 'pace', 'deg', 'tyres'];
    return out;
  }

  // ---- mode: TEST_RUN -------------------------------------------------------
  Map<String, dynamic> _test(
      TelemetryFrame tel, List<LapRecord> clean, List<LapRecord> recent) {
    final fuelLaps = recent.where((lp) => lp.fuelConsumed > 0).toList();
    double? fpl;
    if (fuelLaps.isNotEmpty) {
      fpl = fuelLaps.map((lp) => lp.fuelConsumed).reduce((a, b) => a + b) /
          fuelLaps.length;
    }
    final target = (event.get<num>('target_stint_laps', 10)!).toInt();
    final tail = _stintTail(clean);
    final out = <String, dynamic>{
      'tire_compound': event.get<String>('tire_compound', 'RH'),
      'fuel_per_lap_l': fpl != null ? roundN(fpl, 2) : null,
      'fuel_now_l': roundN(tel.currentFuel, 1),
      'fuel_pct': roundN(tel.fuelPct, 1),
      'stint_target': target,
      'stint_done': tail.length,
      'fuel_range_laps':
          fpl != null ? roundN(tel.currentFuel / fpl, 1) : null,
      'alert': 'ok',
      'alert_msg': '',
    };
    out.addAll(_degBlock(clean, target));
    out['cards'] = ['test', 'pace', 'deg', 'tyres'];
    return out;
  }

  // ---- mode: TIME_TRIAL / REFERENCE -----------------------------------------
  Map<String, dynamic> _timeTrial(TelemetryFrame tel) {
    final refMs = reference?.bestLapMs;
    double? delta, lastDelta;
    if (refMs != null && refMs != 0 && tel.bestLapMs > 0) {
      delta = (tel.bestLapMs - refMs) / 1000.0;
    }
    if (refMs != null && refMs != 0 && tel.lastLapMs > 0) {
      lastDelta = (tel.lastLapMs - refMs) / 1000.0;
    }
    return {
      'tire_compound': event.get<String>('tire_compound', 'RS'),
      'reference_lap_str':
          (refMs != null && refMs != 0) ? fmtMs(refMs) : 'no reference',
      'delta_best_to_ref_s': delta != null ? roundN(delta, 3) : null,
      'delta_last_to_ref_s': lastDelta != null ? roundN(lastDelta, 3) : null,
      'alert': 'ok',
      'alert_msg': '',
      'cards': ['timetrial', 'pace', 'tyres'],
    };
  }

  // ---- entrypoint ------------------------------------------------------------
  Map<String, dynamic> snapshot(
      TelemetryFrame tel, List<LapRecord> laps, double now) {
    final clean = _clean(laps);
    final recent = clean.length > raceCfg.cleanLapWindow
        ? clean.sublist(clean.length - raceCfg.cleanLapWindow)
        : clean;
    final (base, avgMs) = _paceBlock(tel, recent);
    base.addAll({
      'connected': tel.connected,
      'in_race': tel.inRace,
      'paused': tel.isPaused,
      'event_type': event.type.value,
      'track_name': event.get<String>('track_name', '') ?? '',
      'tyre_temps': {
        'fl': roundN(tel.tyreTempFl, 1),
        'fr': roundN(tel.tyreTempFr, 1),
        'rl': roundN(tel.tyreTempRl, 1),
        'rr': roundN(tel.tyreTempRr, 1),
      },
    });

    switch (event.type) {
      case EventType.race:
        base.addAll(_race(tel, clean, recent, avgMs, now));
      case EventType.testRun:
        base.addAll(_test(tel, clean, recent));
      case EventType.timeTrial || EventType.referenceLap:
        base.addAll(_timeTrial(tel));
      case EventType.baseline:
        base['cards'] = ['pace'];
        base['alert'] = 'ok';
        base['alert_msg'] = 'Baseline recording';
    }
    return base;
  }
}
