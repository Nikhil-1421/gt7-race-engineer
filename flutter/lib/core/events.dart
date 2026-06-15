/// Event types and parameter schemas — mirrors `app/events.py`.
///
/// `schemasPayload()` must deep-equal the Python `schemas_payload()` output
/// (checked by the parity harness); it drives the dynamic config form in the
/// Flutter UI exactly as it drives the PWA's settings drawer.
library;

import 'model.dart';

enum EventType {
  referenceLap('reference_lap'),
  testRun('test_run'),
  timeTrial('time_trial'),
  race('race'),
  baseline('baseline');

  final String value;
  const EventType(this.value);

  static EventType from(String v) =>
      EventType.values.firstWhere((e) => e.value == v,
          orElse: () => throw ArgumentError('unknown event type: $v'));
}

const tires = ['RS', 'RM', 'RH', 'IM', 'WET'];

class ParamSpec {
  final String key;
  final String label;
  final String kind; // int | float | bool | enum | multi_enum | str
  final Object? defaultValue;
  final String unit;
  final List<String>? options;
  final String help;

  const ParamSpec(this.key, this.label, this.kind, this.defaultValue,
      {this.unit = '', this.options, this.help = ''});

  Object? coerce(Object? value) {
    if (value == null) return defaultValue;
    switch (kind) {
      case 'int':
        if (value is int) return value;
        if (value is double) return value.toInt();
        return int.parse(value.toString());
      case 'float':
        if (value is num) return value.toDouble();
        return double.parse(value.toString());
      case 'bool':
        if (value is bool) return value;
        // Python bool() truthiness for the values that can plausibly arrive
        if (value is num) return value != 0;
        if (value is String) return value.isNotEmpty;
        return true;
      case 'enum':
        final v = value.toString();
        if (options != null && !options!.contains(v)) {
          throw ArgumentError('$key=$v not in $options');
        }
        return v;
      case 'multi_enum':
        final vals = value is List
            ? value.map((e) => e.toString()).toList()
            : [value.toString()];
        if (options != null) {
          final bad = vals.where((v) => !options!.contains(v)).toList();
          if (bad.isNotEmpty) {
            throw ArgumentError('$key has invalid $bad, allowed $options');
          }
        }
        return vals;
      default:
        return value.toString();
    }
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'kind': kind,
        'default': defaultValue,
        'unit': unit,
        'options': options,
        'help': help,
      };
}

final Map<EventType, List<ParamSpec>> eventSchemas = {
  EventType.referenceLap: const [
    ParamSpec('track_name', 'Track', 'str', '',
        help: 'Name to store the reference under'),
    ParamSpec('car', 'Car', 'str', ''),
    ParamSpec('from_replay', 'Recording from replay', 'bool', true),
  ],
  EventType.testRun: const [
    ParamSpec('track_name', 'Track', 'str', ''),
    ParamSpec('car', 'Car', 'str', ''),
    ParamSpec('tire_compound', 'Tire', 'enum', 'RH', options: tires),
    ParamSpec('start_fuel', 'Start fuel', 'float', 65.0, unit: 'L'),
    ParamSpec('fuel_multiplier', 'Fuel mult.', 'enum', '3',
        options: ['1', '2', '3', '4', '5', '6']),
    ParamSpec('tire_wear_multiplier', 'Tire-wear mult.', 'enum', '3',
        options: ['1', '2', '3', '4', '5', '6']),
    ParamSpec('target_stint_laps', 'Target stint laps', 'int', 10),
  ],
  EventType.timeTrial: const [
    ParamSpec('track_name', 'Track', 'str', ''),
    ParamSpec('car', 'Car', 'str', ''),
    ParamSpec('tire_compound', 'Tire', 'enum', 'RS', options: tires),
    ParamSpec('reference_track', 'Reference lap (track)', 'str', '',
        help: 'Track name whose stored reference to delta against'),
  ],
  EventType.race: const [
    ParamSpec('track_name', 'Track', 'str', ''),
    ParamSpec('car', 'Car', 'str', ''),
    ParamSpec('race_minutes', 'Race length', 'int', 40, unit: 'min'),
    ParamSpec('mandatory_stops', 'Mandatory stops', 'int', 1),
    ParamSpec('required_tires', 'Required tires', 'multi_enum',
        ['RS', 'RM', 'RH'],
        options: tires,
        help: 'Compounds that must be used; RH stint is mandatory in this series'),
    ParamSpec('refuel_rate_lps', 'Refuel rate', 'float', 9.0, unit: 'L/s'),
    ParamSpec('pit_lane_loss_s', 'Pit-lane loss', 'float', 22.0,
        unit: 's', help: 'Auto-filled from track baseline when available'),
    ParamSpec('fuel_buffer_laps', 'Fuel buffer', 'float', 0.6, unit: 'laps'),
  ],
  EventType.baseline: const [
    ParamSpec('track_name', 'Track', 'str', ''),
    ParamSpec('car', 'Car', 'str', ''),
    ParamSpec('measure_pit_loss', 'Calibrate pit loss', 'bool', true,
        help: 'Run a normal lap then a pit lap to measure time loss'),
  ],
};

class EventConfig {
  final EventType type;
  final Map<String, Object?> values;

  const EventConfig(this.type, this.values);

  factory EventConfig.build(Object type, [Map<String, Object?>? overrides]) {
    final et = type is EventType ? type : EventType.from(type.toString());
    final schema = eventSchemas[et]!;
    final values = <String, Object?>{};
    for (final spec in schema) {
      final raw = (overrides ?? const {}).containsKey(spec.key)
          ? overrides![spec.key]
          : spec.defaultValue;
      values[spec.key] = spec.coerce(raw);
    }
    return EventConfig(et, values);
  }

  T? get<T>(String key, [T? fallback]) {
    final v = values[key];
    if (v == null) return fallback;
    if (T == double && v is int) return v.toDouble() as T;
    return v as T;
  }

  RaceConfig raceConfig() => RaceConfig(
        raceSeconds: (get<num>('race_minutes', 40)!).toInt() * 60,
        mandatoryStops: (get<num>('mandatory_stops', 1)!).toInt(),
        refuelRateLps: (get<num>('refuel_rate_lps', 9.0)!).toDouble(),
        pitLaneLossS: (get<num>('pit_lane_loss_s', 22.0)!).toDouble(),
        fuelBufferLaps: (get<num>('fuel_buffer_laps', 0.6)!).toDouble(),
      );

  Map<String, dynamic> toJson() => {'type': type.value, 'values': values};
}

/// Serialisable schema map — must deep-equal Python's `schemas_payload()`.
Map<String, dynamic> schemasPayload() => {
      for (final e in EventType.values)
        e.value: eventSchemas[e]!.map((s) => s.toJson()).toList(),
    };
