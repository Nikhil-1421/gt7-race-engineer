/// Post-session analysis — the parity-locked Dart twin of `app/analysis.py`.
///
/// Given a target lap and a reference lap (each a [LapTrace] of position +
/// speed + pedals + time), this builds cumulative distance, resamples both onto
/// a common distance grid, computes the delta-time trace, segments the lap into
/// loss zones, and diagnoses each zone. [comparisonTraces] returns the per-
/// channel arrays + the racing line (x/z) on the same grid so a single cursor
/// distance links every chart and the map.
///
/// The numeric outputs are rounded to the same decimals as the Python
/// reference so they compare clean (within the harness's float tolerance)
/// against the generated vectors. The resampler matches `numpy.interp`
/// (clamped ends, linear between strictly-increasing samples).
library;

import 'dart:math';

class LapTrace {
  final List<double> x;
  final List<double> z;
  final List<double> speed; // km/h
  final List<double> throttle; // 0-100
  final List<double> brake; // 0-100
  final List<double> tMs; // cumulative ms from lap start
  final String label;

  const LapTrace({
    required this.x,
    required this.z,
    required this.speed,
    required this.throttle,
    required this.brake,
    required this.tMs,
    this.label = '',
  });

  factory LapTrace.fromJson(Map<String, dynamic> j) {
    List<double> a(String k) =>
        ((j[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    return LapTrace(
      x: a('x'),
      z: a('z'),
      speed: a('speed'),
      throttle: a('throttle'),
      brake: a('brake'),
      tMs: a('t_ms'),
      label: j['label'] as String? ?? '',
    );
  }

  bool get usable => x.length >= 3;
}

// --------------------------------------------------------------- primitives

double _round(double v, int nd) {
  if (!v.isFinite) return v;
  final p = pow(10, nd).toDouble();
  return (v * p).round() / p;
}

List<double> _cumDist(List<double> x, List<double> z) {
  final d = List<double>.filled(x.length, 0.0);
  for (var i = 1; i < x.length; i++) {
    final dx = x[i] - x[i - 1], dz = z[i] - z[i - 1];
    d[i] = d[i - 1] + sqrt(dx * dx + dz * dz);
  }
  return d;
}

List<double> _linspace(double a, double b, int n) {
  if (n <= 1) return [a];
  final out = List<double>.filled(n, 0.0);
  final step = (b - a) / (n - 1);
  for (var i = 0; i < n; i++) {
    out[i] = a + step * i;
  }
  out[n - 1] = b; // exact endpoint, like numpy.linspace(endpoint=True)
  return out;
}

/// numpy.interp-equivalent for a strictly-increasing-filtered series.
List<double> _resample(
    List<double> dist, List<double> chan, List<double> grid) {
  // keep index 0, then any point whose original distance increased
  final xs = <double>[];
  final ys = <double>[];
  for (var i = 0; i < dist.length; i++) {
    if (i == 0 || dist[i] > dist[i - 1]) {
      xs.add(dist[i]);
      ys.add(chan[i]);
    }
  }
  final out = List<double>.filled(grid.length, 0.0);
  if (xs.isEmpty) return out;
  for (var g = 0; g < grid.length; g++) {
    final xq = grid[g];
    if (xq <= xs.first) {
      out[g] = ys.first;
    } else if (xq >= xs.last) {
      out[g] = ys.last;
    } else {
      var lo = 0, hi = xs.length - 1;
      while (hi - lo > 1) {
        final mid = (lo + hi) >> 1;
        if (xs[mid] <= xq) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final t = (xq - xs[lo]) / (xs[hi] - xs[lo]);
      out[g] = ys[lo] + t * (ys[hi] - ys[lo]);
    }
  }
  return out;
}

int? _sectorOf(double d, List<double>? sectors) {
  if (sectors == null || sectors.isEmpty) return null;
  for (var i = 0; i < sectors.length; i++) {
    if (d <= sectors[i]) return i + 1;
  }
  return sectors.length + 1;
}

double _minOf(List<double> a, int i, int j) {
  var m = a[i];
  for (var k = i + 1; k < j; k++) {
    if (a[k] < m) m = a[k];
  }
  return m;
}

// ------------------------------------------------------------------ analyze

Map<String, dynamic> analyze(
  LapTrace target,
  LapTrace reference, {
  List<double>? sectorBoundsM,
  int nGrid = 800,
  int nZones = 5,
  double minZoneLossS = 0.03,
}) {
  final td = _cumDist(target.x, target.z);
  final rd = _cumDist(reference.x, reference.z);
  final L = min(td.last, rd.last);
  final grid = _linspace(0, L, nGrid);

  final tTime = _resample(td, target.tMs, grid);
  final rTime = _resample(rd, reference.tMs, grid);
  final delta = List<double>.generate(
      grid.length, (i) => (tTime[i] - rTime[i]) / 1000.0);
  final d0 = delta[0];
  for (var i = 0; i < delta.length; i++) {
    delta[i] -= d0;
  }
  final totalDelta = delta.last;

  final tSpeed = _resample(td, target.speed, grid);
  final rSpeed = _resample(rd, reference.speed, grid);
  final tBrake = _resample(td, target.brake, grid);
  final rBrake = _resample(rd, reference.brake, grid);
  final tThr = _resample(td, target.throttle, grid);
  final rThr = _resample(rd, reference.throttle, grid);

  // rate of time loss; dloss[i] = delta[i] - delta[i-1] (prepend delta[0])
  final zones = <Map<String, dynamic>>[];
  var i = 0;
  while (i < grid.length) {
    final prev = i == 0 ? delta[0] : delta[i - 1];
    if (!(delta[i] - prev > 0)) {
      i++;
      continue;
    }
    var j = i;
    while (j < grid.length) {
      final p = j == 0 ? delta[0] : delta[j - 1];
      if (!(delta[j] - p > 0)) break;
      j++;
    }
    final lost = delta[j - 1] - delta[i];
    if (lost >= minZoneLossS) {
      zones.add(_diagnose(grid, i, j, lost, sectorBoundsM, tSpeed, rSpeed,
          tBrake, rBrake, tThr, rThr));
    }
    i = j;
  }

  zones.sort((a, b) =>
      (b['time_lost_s'] as double).compareTo(a['time_lost_s'] as double));
  final top = zones.take(nZones).toList();

  final dist = <double>[];
  final dlt = <double>[];
  for (var k = 0; k < grid.length; k += 20) {
    dist.add(_round(grid[k], 1));
    dlt.add(_round(delta[k], 3));
  }

  return {
    'target': target.label,
    'reference': reference.label,
    'total_delta_s': _round(totalDelta, 3),
    'lap_length_m': _round(L, 0),
    'n_loss_zones': zones.length,
    'improvements': top,
    'delta_trace': {'dist_m': dist, 'delta_s': dlt},
  };
}

Map<String, dynamic> _diagnose(
    List<double> grid,
    int i,
    int j,
    double lost,
    List<double>? sectors,
    List<double> tSpeed,
    List<double> rSpeed,
    List<double> tBrake,
    List<double> rBrake,
    List<double> tThr,
    List<double> rThr) {
  final startM = grid[i], endM = grid[j - 1];
  final notes = <String>[];
  const brakeTh = 8.0, thrTh = 80.0;

  double? firstDist(bool Function(int) pred) {
    for (var k = i; k < j; k++) {
      if (pred(k)) return grid[k];
    }
    return null;
  }

  final tb = firstDist((k) => tBrake[k] > brakeTh);
  final rb = firstDist((k) => rBrake[k] > brakeTh);
  if (tb != null && rb != null) {
    final d = tb - rb;
    if (d < -4) {
      notes.add('Braking ${d.abs().toStringAsFixed(0)} m too early');
    } else if (d > 4) {
      notes.add(
          'Braking ${d.toStringAsFixed(0)} m later than reference (good — or overdriving)');
    }
  }

  final tMin = _minOf(tSpeed, i, j);
  final rMin = _minOf(rSpeed, i, j);
  if (rMin - tMin > 3) {
    notes.add('Carrying ${(rMin - tMin).toStringAsFixed(0)} km/h less mid-corner');
  }

  final ttOn = firstDist((k) => tThr[k] > thrTh);
  final rtOn = firstDist((k) => rThr[k] > thrTh);
  if (ttOn != null && rtOn != null && ttOn - rtOn > 5) {
    notes.add('Back to full throttle ${(ttOn - rtOn).toStringAsFixed(0)} m later');
  }

  var coastN = 0, coastTot = 0;
  for (var k = i; k < j; k++) {
    coastTot++;
    if (tThr[k] < 5 && tBrake[k] < 5) coastN++;
  }
  final coast = coastTot == 0 ? 0.0 : coastN / coastTot;
  if (coast > 0.18) {
    notes.add('Coasting ${(coast * 100).toStringAsFixed(0)}% of this zone — commit earlier');
  }

  if (notes.isEmpty) notes.add('Small line/exit loss');

  return {
    'start_m': _round(startM, 0),
    'end_m': _round(endM, 0),
    'time_lost_s': _round(lost, 3),
    'sector': _sectorOf(startM, sectors),
    'notes': notes,
  };
}

// -------------------------------------------------------- comparison traces

Map<String, dynamic> comparisonTraces(
  LapTrace target,
  LapTrace reference, {
  int nGrid = 400,
  int nOut = 200,
}) {
  final td = _cumDist(target.x, target.z);
  final rd = _cumDist(reference.x, reference.z);
  final L = min(td.last, rd.last);
  final grid = _linspace(0, L, nGrid);

  final tTime = _resample(td, target.tMs, grid);
  final rTime = _resample(rd, reference.tMs, grid);
  final delta = List<double>.generate(
      grid.length, (i) => (tTime[i] - rTime[i]) / 1000.0);
  final d0 = delta[0];
  for (var i = 0; i < delta.length; i++) {
    delta[i] -= d0;
  }

  final tSpeed = _resample(td, target.speed, grid);
  final rSpeed = _resample(rd, reference.speed, grid);
  final tThr = _resample(td, target.throttle, grid);
  final rThr = _resample(rd, reference.throttle, grid);
  final tBrk = _resample(td, target.brake, grid);
  final rBrk = _resample(rd, reference.brake, grid);
  final lineX = _resample(td, target.x, grid);
  final lineZ = _resample(td, target.z, grid);

  final step = max(1, nGrid ~/ nOut);
  List<double> r(List<double> a, int nd) {
    final out = <double>[];
    for (var k = 0; k < a.length; k += step) {
      out.add(_round(a[k], nd));
    }
    return out;
  }

  return {
    'available': true,
    'target': target.label,
    'reference': reference.label,
    'lap_length_m': _round(L, 0),
    'dist_m': r(grid, 1),
    't_speed': r(tSpeed, 1),
    'r_speed': r(rSpeed, 1),
    't_throttle': r(tThr, 0),
    'r_throttle': r(rThr, 0),
    't_brake': r(tBrk, 0),
    'r_brake': r(rBrk, 0),
    'delta_s': r(delta, 3),
    'line_x': r(lineX, 1),
    'line_z': r(lineZ, 1),
  };
}