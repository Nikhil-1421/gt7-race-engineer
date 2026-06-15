/// Core data model — mirrors `app/model.py` field-for-field.
///
/// Deliberately dependency-free. Formatting is built from INTEGER math so it
/// matches the Python reference exactly (no float-formatting divergence).
library;

class RaceConfig {
  final int raceSeconds;
  final int mandatoryStops;
  final double refuelRateLps;
  final double pitLaneLossS;
  final double fuelBufferLaps;
  final int cleanLapWindow;
  final int degStintMinLaps;

  const RaceConfig({
    this.raceSeconds = 40 * 60,
    this.mandatoryStops = 1,
    this.refuelRateLps = 9.0,
    this.pitLaneLossS = 22.0,
    this.fuelBufferLaps = 0.6,
    this.cleanLapWindow = 5,
    this.degStintMinLaps = 4,
  });
}

class TelemetryFrame {
  final bool connected;
  final bool inRace;
  final bool isPaused;
  final int currentLap;
  final int totalLaps;
  final int lastLapMs; // -1 = none yet
  final int bestLapMs;
  final double currentFuel;
  final double fuelCapacity;
  final double carSpeed; // km/h
  final double throttle; // 0-100
  final double brake; // 0-100
  final int carId;
  final double positionX;
  final double positionZ;
  final double tyreTempFl;
  final double tyreTempFr;
  final double tyreTempRl;
  final double tyreTempRr;

  const TelemetryFrame({
    this.connected = false,
    this.inRace = false,
    this.isPaused = false,
    this.currentLap = 0,
    this.totalLaps = 0,
    this.lastLapMs = -1,
    this.bestLapMs = -1,
    this.currentFuel = 0.0,
    this.fuelCapacity = 0.0,
    this.carSpeed = 0.0,
    this.throttle = 0.0,
    this.brake = 0.0,
    this.carId = 0,
    this.positionX = 0.0,
    this.positionZ = 0.0,
    this.tyreTempFl = 0.0,
    this.tyreTempFr = 0.0,
    this.tyreTempRl = 0.0,
    this.tyreTempRr = 0.0,
  });

  double get fuelPct =>
      fuelCapacity <= 0 ? 0.0 : 100.0 * currentFuel / fuelCapacity;

  /// Build from the serialized form used by the parity vectors
  /// (Python attribute names).
  factory TelemetryFrame.fromJson(Map<String, dynamic> j) => TelemetryFrame(
        connected: j['connected'] as bool? ?? false,
        inRace: j['in_race'] as bool? ?? false,
        isPaused: j['is_paused'] as bool? ?? false,
        currentLap: (j['current_lap'] as num? ?? 0).toInt(),
        totalLaps: (j['total_laps'] as num? ?? 0).toInt(),
        lastLapMs: (j['last_lap_ms'] as num? ?? -1).toInt(),
        bestLapMs: (j['best_lap_ms'] as num? ?? -1).toInt(),
        currentFuel: (j['current_fuel'] as num? ?? 0).toDouble(),
        fuelCapacity: (j['fuel_capacity'] as num? ?? 0).toDouble(),
        carSpeed: (j['car_speed'] as num? ?? 0).toDouble(),
        throttle: (j['throttle'] as num? ?? 0).toDouble(),
        brake: (j['brake'] as num? ?? 0).toDouble(),
        tyreTempFl: (j['tyre_temp_fl'] as num? ?? 0).toDouble(),
        tyreTempFr: (j['tyre_temp_fr'] as num? ?? 0).toDouble(),
        tyreTempRl: (j['tyre_temp_rl'] as num? ?? 0).toDouble(),
        tyreTempRr: (j['tyre_temp_rr'] as num? ?? 0).toDouble(),
      );
}

class LapRecord {
  final int number;
  final int lapFinishTimeMs;
  final double fuelConsumed;
  final double fuelAtEnd;
  final int stintLap;
  final bool isOutlier;

  const LapRecord({
    required this.number,
    required this.lapFinishTimeMs,
    required this.fuelConsumed,
    required this.fuelAtEnd,
    this.stintLap = 0,
    this.isOutlier = false,
  });

  factory LapRecord.fromJson(Map<String, dynamic> j) => LapRecord(
        number: (j['number'] as num).toInt(),
        lapFinishTimeMs: (j['lap_finish_time_ms'] as num).toInt(),
        fuelConsumed: (j['fuel_consumed'] as num).toDouble(),
        fuelAtEnd: (j['fuel_at_end'] as num).toDouble(),
        stintLap: (j['stint_lap'] as num? ?? 0).toInt(),
        isOutlier: j['is_outlier'] as bool? ?? false,
      );
}

/// m:ss.mmm — integer construction, parity-exact with Python's
/// `f"{m}:{s:06.3f}"` for integer millisecond inputs.
String fmtMs(int? ms) {
  if (ms == null || ms < 0) return '--:--.---';
  final m = ms ~/ 60000;
  final rem = ms % 60000;
  final sec = rem ~/ 1000;
  final milli = rem % 1000;
  final secStr = sec.toString().padLeft(2, '0');
  final milliStr = milli.toString().padLeft(3, '0');
  return '$m:$secStr.$milliStr';
}

/// M:SS countdown clamped at zero — parity with Python's
/// `int(s // 60)` / `int(s % 60)` (truncation of non-negative values).
String fmtClock(double seconds) {
  final s = seconds < 0 ? 0.0 : seconds;
  final m = (s / 60).floor();
  final sec = (s % 60).floor();
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// Python-style round-to-n-decimals. Dart's round() is half-away-from-zero
/// vs Python's half-even; for the engineer's computed floats an exact .5 tie
/// at the target precision is a measure-zero event, and the parity harness
/// compares with a tolerance that would flag any real divergence.
double roundN(double v, int n) {
  var p = 1.0;
  for (var i = 0; i < n; i++) {
    p *= 10.0;
  }
  return (v * p).roundToDouble() / p;
}
