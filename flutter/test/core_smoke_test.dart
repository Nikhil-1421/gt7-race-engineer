import 'package:flutter_test/flutter_test.dart';
import 'package:gt7_race_engineer/core/engineer.dart';
import 'package:gt7_race_engineer/core/events.dart';
import 'package:gt7_race_engineer/core/model.dart';

/// Fast sanity layer for `flutter test`. The real correctness guarantee is
/// the parity harness (tool/parity/run_parity.dart) replaying
/// Python-generated vectors; this just keeps the package importable and the
/// obvious invariants pinned.
void main() {
  test('lap formatting is integer-exact', () {
    expect(fmtMs(94500), '1:34.500');
    expect(fmtMs(60000), '1:00.000');
    expect(fmtMs(-1), '--:--.---');
    expect(fmtMs(null), '--:--.---');
    expect(fmtClock(125.9), '2:05');
    expect(fmtClock(-3), '0:00');
  });

  test('schemas cover all five modes', () {
    final p = schemasPayload();
    expect(p.keys.toSet(),
        {'race', 'test_run', 'time_trial', 'reference_lap', 'baseline'});
    final race = (p['race'] as List).cast<Map<String, dynamic>>();
    expect(race.any((s) => s['key'] == 'race_minutes'), isTrue);
  });

  test('event config coerces like the Python reference', () {
    final cfg = EventConfig.build('race', {'race_minutes': '45'});
    expect(cfg.values['race_minutes'], 45);
    expect(cfg.values['refuel_rate_lps'], 9.0);
    expect(() => EventConfig.build('race', {'required_tires': ['XX']}),
        throwsArgumentError);
  });

  test('race engineer emits its card set from a cold start', () {
    final eng = SessionEngineer(EventConfig.build('race'));
    final snap = eng.snapshot(const TelemetryFrame(), const [], 0.0);
    expect(snap['cards'], ['fuel', 'pit', 'pace', 'deg', 'tyres']);
    expect(snap['event_type'], 'race');
    expect(snap['last_lap_str'], '--:--.---');
  });
}
