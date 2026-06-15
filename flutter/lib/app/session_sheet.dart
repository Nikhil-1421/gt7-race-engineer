/// Session settings sheet — the native counterpart of the PWA's drawer.
///
/// The form is generated from [schemasPayload], the same structure the
/// Python server serves at `/schemas` (deep-equality is parity-tested), so
/// adding a parameter to `events` in either codebase grows both UIs.
library;

import 'package:flutter/material.dart';

import '../core/events.dart';
import '../core/model.dart';
import 'app_state.dart';

const Map<String, String> modeLabels = {
  'race': 'RACE',
  'time_trial': 'TIME TRIAL',
  'test_run': 'TEST RUN',
  'reference_lap': 'REFERENCE',
  'baseline': 'BASELINE',
};

class SessionSheet extends StatefulWidget {
  final AppState state;
  const SessionSheet({super.key, required this.state});

  @override
  State<SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<SessionSheet> {
  late final Map<String, dynamic> _schemas = schemasPayload();
  late String _type = widget.state.event.type.value;
  final Map<String, Object?> _values = {}; // bool / enum / multi_enum / catalog
  final Map<String, TextEditingController> _text = {}; // int / float / str
  final List<TextEditingController> _retired = []; // disposed with the sheet
  // ephemeral cascade selections (the parent levels; the leaf is the stored value)
  String? _trackVenue;
  String? _carCategory;
  String? _carCountry;
  late final TextEditingController _ref = TextEditingController(
      text: widget.state.reference != null
          ? fmtMs(widget.state.reference!.bestLapMs)
          : '');

  @override
  void initState() {
    super.initState();
    _seed(fromCurrent: true);
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final c in _retired) {
      c.dispose();
    }
    _ref.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _specs =>
      (_schemas[_type] as List).cast<Map<String, dynamic>>();

  void _seed({required bool fromCurrent}) {
    // Old controllers may still be attached to fields this frame — retire
    // them and dispose when the sheet itself is disposed.
    _retired.addAll(_text.values);
    _text.clear();
    _values.clear();
    final current =
        fromCurrent ? widget.state.event.values : const <String, Object?>{};
    for (final spec in _specs) {
      final key = spec['key'] as String;
      final kind = spec['kind'] as String;
      final v = current.containsKey(key) ? current[key] : spec['default'];
      switch (kind) {
        case 'int' || 'float' || 'str':
          if (key == 'track_name' || key == 'car') {
            _values[key] = (v ?? '').toString(); // catalog cascade leaf
          } else {
            _text[key] = TextEditingController(text: v?.toString() ?? '');
          }
        case 'multi_enum':
          _values[key] =
              List<String>.from((v as List?)?.map((e) => e.toString()) ?? []);
        default: // bool, enum
          _values[key] = v;
      }
    }
    // derive cascade parent levels from the current leaf values
    final cat = widget.state.catalog;
    _trackVenue = cat.venueForLayout((_values['track_name'] ?? '').toString());
    final loc = cat.locateCar((_values['car'] ?? '').toString());
    _carCategory = loc.$1;
    _carCountry = loc.$2;
  }

  void _selectType(String t) {
    if (t == _type) return;
    setState(() {
      _type = t;
      _seed(fromCurrent: t == widget.state.event.type.value);
    });
  }

  int? _parseLapMs(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.contains(':')) {
      final parts = t.split(':');
      final m = int.parse(parts[0]);
      final s = double.parse(parts[1]);
      return (m * 60000 + s * 1000).round();
    }
    return (double.parse(t) * 1000).round(); // plain seconds
  }

  void _start() {
    final vals = <String, Object?>{};
    _text.forEach((k, c) {
      final t = c.text.trim();
      if (t.isNotEmpty) vals[k] = t; // EventConfig coerces, like the server
    });
    vals.addAll(_values);
    try {
      if (_type == 'time_trial' || _type == 'reference_lap') {
        widget.state.setReferenceMs(_parseLapMs(_ref.text));
      }
      widget.state.setEvent(_type, vals);
      Navigator.of(context).pop();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Check your inputs — $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Session',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in modeLabels.keys)
                      ChoiceChip(
                        label: Text(modeLabels[t]!,
                            style: const TextStyle(fontSize: 12)),
                        selected: _type == t,
                        onSelected: (_) => _selectType(t),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final spec in _specs) _field(spec),
                if (_type == 'time_trial' || _type == 'reference_lap')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextField(
                      controller: _ref,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Reference lap',
                        hintText: '1:34.500  (or plain seconds)',
                        helperText:
                            'Manual target to delta against — leave empty '
                            'for none',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.flag),
                  label: const Text('Start session'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(Map<String, dynamic> spec) {
    final key = spec['key'] as String;
    final kind = spec['kind'] as String;
    final label = spec['label'] as String;
    final unit = spec['unit'] as String? ?? '';
    final help = spec['help'] as String? ?? '';
    final options = (spec['options'] as List?)?.cast<String>();

    if (key == 'track_name') return _trackCascade(spec);
    if (key == 'car') return _carCascade(spec);

    switch (kind) {
      case 'bool':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: help.isNotEmpty
              ? Text(help, style: const TextStyle(fontSize: 12))
              : null,
          value: _values[key] as bool? ?? false,
          onChanged: (v) => setState(() => _values[key] = v),
        );
      case 'enum':
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _values[key] as String?,
            items: [
              for (final o in options ?? const <String>[])
                DropdownMenuItem(value: o, child: Text(o)),
            ],
            onChanged: (v) => setState(() => _values[key] = v),
            decoration: InputDecoration(
              labelText: label,
              helperText: help.isNotEmpty ? help : null,
              border: const OutlineInputBorder(),
            ),
          ),
        );
      case 'multi_enum':
        final sel = (_values[key] as List?)?.cast<String>() ?? <String>[];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        const TextStyle(fontSize: 13, color: Colors.white70)),
                if (help.isNotEmpty)
                  Text(help,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final o in options ?? const <String>[])
                    FilterChip(
                      label: Text(o),
                      selected: sel.contains(o),
                      onSelected: (on) => setState(() {
                        final list =
                            List<String>.from(sel)..removeWhere((x) => x == o);
                        if (on) list.add(o);
                        _values[key] = list;
                      }),
                    ),
                ]),
              ]),
        );
      default: // int / float / str
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: _text[key],
            keyboardType: kind == 'str'
                ? TextInputType.text
                : TextInputType.numberWithOptions(decimal: kind == 'float'),
            decoration: InputDecoration(
              labelText: label,
              suffixText: unit.isNotEmpty ? unit : null,
              helperText: help.isNotEmpty ? help : null,
              border: const OutlineInputBorder(),
            ),
          ),
        );
    }
  }

  // ---- catalog cascades -----------------------------------------------------
  Widget _dropdown(String label, String? value, List<String> options,
      ValueChanged<String?> onChanged, {String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        // ignore: deprecated_member_use
        value: (value != null && options.contains(value)) ? value : null,
        isExpanded: true,
        items: [
          for (final o in options)
            DropdownMenuItem(
                value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
        decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            border: const OutlineInputBorder()),
      ),
    );
  }

  /// Free-text fallback (catalog empty / value not in catalog) writing _values.
  Widget _plainText(Map<String, dynamic> spec) {
    final key = spec['key'] as String;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        initialValue: (_values[key] ?? '').toString(),
        onChanged: (v) => _values[key] = v,
        decoration: InputDecoration(
          labelText: spec['label'] as String,
          helperText: (spec['help'] as String?)?.isNotEmpty == true
              ? spec['help'] as String
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _trackCascade(Map<String, dynamic> spec) {
    final cat = widget.state.catalog;
    if (!cat.hasTracks) return _plainText(spec);
    final layout = (_values['track_name'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _dropdown('Track', _trackVenue, cat.venueNames(), (v) => setState(() {
              _trackVenue = v;
              _values['track_name'] = '';
            })),
        _dropdown(
            'Layout',
            layout.isEmpty ? null : layout,
            cat.layoutsForVenue(_trackVenue),
            (v) => setState(() => _values['track_name'] = v ?? ''),
            helper: (spec['help'] as String?)?.isNotEmpty == true
                ? spec['help'] as String
                : null),
      ]),
    );
  }

  Widget _carCascade(Map<String, dynamic> spec) {
    final cat = widget.state.catalog;
    if (!cat.hasCars) return _plainText(spec);
    final car = (_values['car'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _dropdown('Car category', _carCategory, cat.categoryNames(),
            (v) => setState(() {
                  _carCategory = v;
                  _carCountry = null;
                  _values['car'] = '';
                })),
        _dropdown('Manufacturer country', _carCountry,
            cat.countriesForCategory(_carCategory), (v) => setState(() {
                  _carCountry = v;
                  _values['car'] = '';
                })),
        _dropdown('Car', car.isEmpty ? null : car,
            cat.carsFor(_carCategory, _carCountry),
            (v) => setState(() => _values['car'] = v ?? '')),
      ]),
    );
  }
}
