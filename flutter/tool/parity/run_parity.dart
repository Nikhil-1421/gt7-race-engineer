/// Parity harness — replays the Python-generated vectors through the Dart
/// core and fails loudly on any divergence.
///
/// Run from the `flutter/` directory with the plain Dart SDK (no Flutter
/// needed):
///
///     dart tool/parity/run_parity.dart
///
/// Regenerate vectors from the Python reference with
/// `python tools/gen_parity_vectors.py` in the repo root.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../lib/core/analysis.dart';
import '../../lib/core/callouts.dart';
import '../../lib/core/engineer.dart';
import '../../lib/core/events.dart';
import '../../lib/core/model.dart';
import '../../lib/core/packet.dart';
import '../../lib/core/salsa20.dart';

int checks = 0, failures = 0;
final List<String> failLog = [];

void fail(String path, Object? got, Object? want) {
  failures++;
  if (failLog.length < 40) failLog.add('  $path\n    got:  $got\n    want: $want');
}

bool _numEq(num a, num b) =>
    (a - b).abs() <= 1e-9 + 1e-6 * b.abs().clamp(1, double.infinity);

void deepCompare(Object? got, Object? want, String path) {
  checks++;
  if (want == null || got == null) {
    if (got != want) fail(path, got, want);
    return;
  }
  if (want is num && got is num) {
    if (!_numEq(got, want)) fail(path, got, want);
    return;
  }
  if (want is bool || want is String) {
    if (got != want) fail(path, got, want);
    return;
  }
  if (want is List) {
    if (got is! List || got.length != want.length) {
      fail(path, got, want);
      return;
    }
    for (var i = 0; i < want.length; i++) {
      deepCompare(got[i], want[i], '$path[$i]');
    }
    return;
  }
  if (want is Map) {
    if (got is! Map) {
      fail(path, got, want);
      return;
    }
    for (final k in want.keys) {
      deepCompare(got[k], want[k], '$path.$k');
    }
    for (final k in got.keys) {
      if (!want.containsKey(k)) fail('$path.$k', got[k], '<absent>');
    }
    return;
  }
  fail(path, got, want);
}

Uint8List hexBytes(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> loadJson(String name) {
  final path = '${Directory.current.path}/tool/parity/vectors/$name';
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

// ---------------------------------------------------------------- families

void testSalsa() {
  final v = loadJson('salsa20.json');
  final key = hexBytes(v['key_hex'] as String);
  for (final (i, c) in (v['raw'] as List).indexed) {
    final nonce = hexBytes(c['nonce_hex'] as String);
    final want = c['keystream_hex'] as String;
    final got =
        bytesHex(salsa20Xor(key, nonce, Uint8List(want.length ~/ 2)));
    checks++;
    if (got != want) fail('salsa20.raw[$i]', got, want);
  }
}

void testPackets() {
  final v = loadJson('packets.json');
  for (final (i, c) in (v['cases'] as List).indexed) {
    final pkt = decryptAndParse(hexBytes(c['cipher_hex'] as String));
    if (pkt == null) {
      fail('packets[$i]', 'decrypt rejected', 'parsed packet');
      continue;
    }
    final f = pkt.frame;
    final got = <String, dynamic>{
      'package_id': pkt.packageId,
      'current_lap': f.currentLap,
      'total_laps': f.totalLaps,
      'best_lap_ms': f.bestLapMs,
      'last_lap_ms': f.lastLapMs,
      'current_fuel': f.currentFuel,
      'fuel_capacity': f.fuelCapacity,
      'car_speed_kmh': f.carSpeed,
      'throttle': f.throttle,
      'brake': f.brake,
      'in_race': f.inRace,
      'is_paused': f.isPaused,
      'current_gear': pkt.currentGear,
      'suggested_gear': pkt.suggestedGear,
      'car_id': f.carId,
      'position_x': f.positionX,
      'position_y': pkt.positionY,
      'position_z': f.positionZ,
      'tyre_temp_fl': f.tyreTempFl,
      'tyre_temp_fr': f.tyreTempFr,
      'tyre_temp_rl': f.tyreTempRl,
      'tyre_temp_rr': f.tyreTempRr,
      'current_position': pkt.currentPosition,
      'total_positions': pkt.totalPositions,
    };
    deepCompare(got, c['fields'], 'packets[$i]');
  }
  checks++;
  if (gt7Decrypt(hexBytes(v['reject_hex'] as String)) != null) {
    fail('packets.reject', 'accepted', 'magic rejection');
  }
}

void testEngineer() {
  final v = loadJson('engineer.json');
  for (final session in v['sessions'] as List) {
    final type = session['event_type'] as String;
    final values =
        (session['values'] as Map).cast<String, Object?>();
    final refMs = session['reference_best_ms'] as int?;
    final eng = SessionEngineer(
      EventConfig.build(type, values),
      reference: refMs != null ? ReferenceLap(refMs) : null,
    );
    for (final (i, sample) in (session['samples'] as List).indexed) {
      final tel = TelemetryFrame.fromJson(
          (sample['tel'] as Map).cast<String, dynamic>());
      final laps = (sample['laps'] as List)
          .map((j) => LapRecord.fromJson((j as Map).cast<String, dynamic>()))
          .toList();
      eng.stopsMade = (sample['stops_made'] as num).toInt();
      final got =
          eng.snapshot(tel, laps, (sample['now'] as num).toDouble());
      deepCompare(got, sample['expect'], 'engineer.$type[$i]');
    }
  }
}

void testCallouts() {
  final v = loadJson('callouts.json');
  for (final mode in ['race', 'time_trial']) {
    final block = v[mode] as Map<String, dynamic>;
    final eng = CalloutEngine();
    final fired = <Map<String, dynamic>>[];
    for (final step in block['script'] as List) {
      final now = (step['now'] as num).toDouble();
      final snap = (step['snap'] as Map).cast<String, dynamic>();
      for (final c in eng.ingest(snap, now)) {
        fired.add({'at': now, ...c.toJson()});
      }
    }
    deepCompare(fired, block['fired'], 'callouts.$mode');
  }
}

void testMisc() {
  final v = loadJson('misc.json');
  deepCompare(schemasPayload(), v['schemas'], 'schemas');
  for (final (i, c) in (v['fmt_ms'] as List).indexed) {
    final got = fmtMs((c['ms'] as num?)?.toInt());
    checks++;
    if (got != c['out']) fail('fmt_ms[$i] (${c['ms']})', got, c['out']);
  }
  for (final (i, c) in (v['fmt_clock'] as List).indexed) {
    final got = fmtClock((c['s'] as num).toDouble());
    checks++;
    if (got != c['out']) fail('fmt_clock[$i] (${c['s']})', got, c['out']);
  }
}

void testAnalysis() {
  final v = loadJson('analysis.json');
  for (final (i, c) in (v['cases'] as List).indexed) {
    final t = LapTrace.fromJson((c['target'] as Map).cast<String, dynamic>());
    final r =
        LapTrace.fromJson((c['reference'] as Map).cast<String, dynamic>());
    deepCompare(comparisonTraces(t, r), c['traces'], 'analysis[$i].traces');
    final rep = analyze(t, r);
    final core = {
      'total_delta_s': rep['total_delta_s'],
      'lap_length_m': rep['lap_length_m'],
      'delta_trace': rep['delta_trace'],
    };
    deepCompare(core, c['analyze_core'], 'analysis[$i].analyze_core');
  }
}

void main() {
  final families = {
    'salsa20': testSalsa,
    'packets': testPackets,
    'engineer': testEngineer,
    'callouts': testCallouts,
    'misc': testMisc,
    'analysis': testAnalysis,
  };
  families.forEach((name, fn) {
    final before = failures;
    fn();
    final mark = failures == before ? 'PASS' : 'FAIL';
    stdout.writeln('[$mark] $name');
  });
  stdout.writeln('\nparity: $checks comparisons, $failures failures');
  if (failures > 0) {
    stdout.writeln(failLog.join('\n'));
    if (failures > failLog.length) {
      stdout.writeln('  … and ${failures - failLog.length} more');
    }
    exit(1);
  }
}