/// Callout engine — port of `app/callouts.py`. The parity harness replays
/// scripted snapshot sequences and requires the same lines, categories,
/// priorities, and firing order.
library;

class Callout {
  final String category;
  final String text;
  final int priority; // 0 highest
  final double ts;
  const Callout(this.category, this.text, this.priority, this.ts);

  Map<String, dynamic> toJson() =>
      {'category': category, 'text': text, 'priority': priority};
}

class CalloutEngine {
  final int fuelUpdateLaps;
  final double degCliffS;
  final double tyreHotC;

  final Map<String, double> _cooldown = {
    'radio_check': 1e9, 'box': 8.0, 'fuel_save': 40.0, 'fuel_critical': 25.0,
    'fuel_update': 1e9, 'deg': 60.0, 'tyre': 45.0, 'laps_to_go': 1e9,
    'pace': 20.0,
  };
  final Map<String, double> _last = {};
  Map<String, dynamic>? _prev;
  bool _boxArmed = true;
  int _lastFuelUpdateLap = 0;
  bool _greeted = false;

  CalloutEngine(
      {this.fuelUpdateLaps = 3, this.degCliffS = 0.15, this.tyreHotC = 110.0});

  bool _ready(String cat, double now) =>
      (now - (_last[cat] ?? -1e9)) >= (_cooldown[cat] ?? 10.0);

  void _fire(List<Callout> out, String cat, String text, int prio, double now) {
    out.add(Callout(cat, text, prio, now));
    _last[cat] = now;
  }

  /// Format a double the way Python's f-string default does for the values
  /// the engine produces ("2.9" not "2.9000..."; integers as "3.0").
  static String _pyNum(num v) {
    if (v is int) return v.toString();
    final d = v.toDouble();
    if (d == d.truncateToDouble()) return '${d.truncate()}.0';
    return d.toString();
  }

  List<Callout> ingest(Map<String, dynamic> snap, double now) {
    var out = <Callout>[];
    if (snap['in_race'] != true) {
      _prev = snap;
      return out;
    }

    if (!_greeted) {
      _greeted = true;
      _fire(out, 'radio_check',
          'Radio check — engineer here, have a good one.', 3, now);
    }

    final et = snap['event_type'];
    if (et == 'race') {
      out.addAll(_raceCalls(snap, now));
    } else if (et == 'test_run') {
      out.addAll(_testCalls(snap, now));
    } else if (et == 'time_trial' || et == 'reference_lap') {
      out.addAll(_ttCalls(snap, now));
    }

    // single highest-priority line per tick (stable: first among ties)
    if (out.isNotEmpty) {
      var best = out.first;
      for (final c in out) {
        if (c.priority < best.priority) best = c;
      }
      out = [best];
    }
    _prev = snap;
    return out;
  }

  // ---- race -----------------------------------------------------------
  List<Callout> _raceCalls(Map<String, dynamic> s, double now) {
    final out = <Callout>[];
    final stopsLeft = s['stops_left'] as num?;
    final fll = (s['fuel_laps_left'] as num?)?.toDouble();
    final bal = (s['fuel_balance_laps'] as num?)?.toDouble();
    final cur = (s['current_lap'] as num? ?? 0).toInt();
    final lapsLeft = s['laps_left_race'] as num?;

    // re-arm the box call after a stop (stint reset)
    if (_prev != null && _prev!['event_type'] == 'race') {
      final stint = (s['stint_lap'] as num? ?? 0).toInt();
      final prevStint = (_prev!['stint_lap'] as num? ?? 0).toInt();
      if (stint <= 1 && prevStint > 1) _boxArmed = true;
    }

    final pitBy = s['pit_by_lap'] as num?;
    final boxDue =
        (fll != null && fll < 1.6) || (pitBy != null && cur >= pitBy);
    final stopsOwed = stopsLeft != null && stopsLeft != 0;
    if (stopsOwed && boxDue && _boxArmed && _ready('box', now)) {
      _fire(out, 'box', 'Box this lap, box, box.', 0, now);
      _boxArmed = false;
    }

    if (stopsLeft != null && stopsLeft == 0 && bal != null) {
      if (bal < -0.3 && _ready('fuel_critical', now)) {
        final tgt = s['fuel_save_target_l'] as num?;
        final extra = (tgt != null && tgt != 0)
            ? ' target ${_pyNum(tgt)} a lap.'
            : '';
        _fire(
            out,
            'fuel_critical',
            "Fuel critical, we're ${bal.abs().toStringAsFixed(1)} short — save now.$extra",
            0,
            now);
      } else if (bal < 0 && _ready('fuel_save', now)) {
        _fire(out, 'fuel_save',
            "Fuel's marginal — lift and coast where you can.", 1, now);
      }
    }

    final deg = (s['deg_per_lap_s'] as num?)?.toDouble();
    if (deg != null && deg >= degCliffS && _ready('deg', now)) {
      _fire(
          out,
          'deg',
          'Tyres dropping off, ${deg.toStringAsFixed(2)} a lap — manage the rears.',
          1,
          now);
    }

    final temps = (s['tyre_temps'] as Map?) ?? const {};
    final hot = <String>[
      for (final e in temps.entries)
        if (e.value is num && (e.value as num) >= tyreHotC)
          e.key.toString().toUpperCase()
    ];
    if (hot.isNotEmpty && _ready('tyre', now)) {
      _fire(out, 'tyre', '${hot.join(', ')} running hot — ease the loading.',
          1, now);
    }

    if (cur != 0 && cur != _lastFuelUpdateLap && cur % fuelUpdateLaps == 0) {
      _lastFuelUpdateLap = cur;
      if (fll != null) {
        final fllStr = fll.toStringAsFixed(1);
        if (bal != null) {
          final sign = bal >= 0 ? 'up' : 'down';
          _fire(
              out,
              'fuel_update',
              'Fuel: $fllStr laps in the tank, $sign ${bal.abs().toStringAsFixed(1)} on the race.',
              2,
              now);
        } else {
          _fire(out, 'fuel_update', 'Fuel: $fllStr laps in the tank.', 2, now);
        }
      }
    }

    if (lapsLeft != null && lapsLeft == 2 && _ready('laps_to_go', now)) {
      _fire(out, 'laps_to_go', 'Two laps to go — bring it home.', 3, now);
    }
    return out;
  }

  // ---- test run --------------------------------------------------------
  List<Callout> _testCalls(Map<String, dynamic> s, double now) {
    final out = <Callout>[];
    final done = (s['stint_done'] as num? ?? 0).toInt();
    final target = (s['stint_target'] as num? ?? 0).toInt();
    final deg = (s['deg_per_lap_s'] as num?)?.toDouble();
    if (target != 0 && done == target && _ready('laps_to_go', now)) {
      final fpl = s['fuel_per_lap_l'];
      _fire(
          out,
          'laps_to_go',
          'Stint target hit — $done laps, ${fpl is num ? _pyNum(fpl) : fpl} a lap, deg ${deg is num ? _pyNum(deg!) : deg} a lap.',
          2,
          now);
    } else if (deg != null && deg >= degCliffS && _ready('deg', now)) {
      _fire(out, 'deg',
          'Deg reading ${deg.toStringAsFixed(2)} a lap on this run.', 2, now);
    }
    return out;
  }

  // ---- time trial --------------------------------------------------------
  List<Callout> _ttCalls(Map<String, dynamic> s, double now) {
    final out = <Callout>[];
    final d = (s['delta_last_to_ref_s'] as num?)?.toDouble();
    if (d != null && _ready('pace', now)) {
      if (d < -0.05) {
        _fire(out, 'pace',
            "That's a ${d.abs().toStringAsFixed(2)} improvement — purple.", 2,
            now);
      } else if (d > 0.15) {
        _fire(
            out,
            'pace',
            'Up ${d.toStringAsFixed(2)} on the reference — find it in the slow stuff.',
            2,
            now);
      }
    }
    return out;
  }
}
