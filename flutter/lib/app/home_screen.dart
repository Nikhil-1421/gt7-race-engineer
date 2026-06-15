/// Home screen — the native counterpart of the PWA dashboard.
///
/// Pure view layer: everything rendered here comes off [AppState.snapshot]
/// (whose keys are parity-tested against the Python reference) plus the
/// callout log. Which cards appear is driven by `snapshot['cards']`, exactly
/// as the web UI is driven by the same field.
library;

import 'package:flutter/material.dart';

import 'analysis_screen.dart';
import 'app_state.dart';
import 'history_screen.dart';
import 'session_sheet.dart';

const _ok = Color(0xFF35C46B);
const _warn = Color(0xFFE9B438);
const _bad = Color(0xFFE25555);
const _dim = Color(0xFF8A929B);
const _surface = Color(0xFF191D21);

class HomeScreen extends StatelessWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.snapshot;
        final cards = (s['cards'] as List?)?.cast<String>() ?? const ['pace'];
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF14171A),
            titleSpacing: 12,
            title: Row(
              children: [
                _statusDot(s),
                const SizedBox(width: 10),
                const Text('Race Engineer',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ],
            ),
            actions: [
              _modePill(s['event_type'] as String? ?? 'race'),
              IconButton(
                tooltip: 'Get Faster — lap comparison',
                icon: const Icon(Icons.timeline),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AnalysisScreen(state: state),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Session history',
                icon: const Icon(Icons.history),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryScreen(state: state),
                  ),
                ),
              ),
              IconButton(
                tooltip: state.ttsEnabled
                    ? 'Mute radio voice'
                    : 'Speak callouts aloud',
                icon: Icon(
                    state.ttsEnabled ? Icons.volume_up : Icons.volume_off,
                    color: state.ttsEnabled ? _ok : _dim),
                onPressed: () => state.setTts(!state.ttsEnabled),
              ),
              IconButton(
                tooltip: 'Session settings',
                icon: const Icon(Icons.tune),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: const Color(0xFF14171A),
                  shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(18))),
                  builder: (_) => SessionSheet(state: state),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              if (state.synthetic || state.sourceError.isNotEmpty) ...[
                _SetupCard(state: state),
                const SizedBox(height: 12),
              ],
              if ((s['alert_msg'] as String? ?? '').isNotEmpty) ...[
                _alertBanner(
                    s['alert'] as String? ?? 'ok', s['alert_msg'] as String),
                const SizedBox(height: 12),
              ],
              if (!state.hiddenCards.contains('live')) ...[
                _liveTelemetry(s),
                const SizedBox(height: 12),
              ],
              for (final c in cards.where((c) => !state.hiddenCards.contains(c))) ...[
                _cardFor(c, s),
                const SizedBox(height: 12),
              ],
              _RadioTicker(log: state.calloutLog),
            ],
          ),
        );
      },
    );
  }

  Widget _statusDot(Map<String, dynamic> s) {
    final Color c;
    if (state.sourceError.isNotEmpty) {
      c = _bad;
    } else if (state.synthetic) {
      c = _warn;
    } else if (s['connected'] == true) {
      c = _ok;
    } else {
      c = _dim;
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle, boxShadow: [
        BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: 6)
      ]),
    );
  }

  Widget _modePill(String type) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
            color: Colors.white10, borderRadius: BorderRadius.circular(999)),
        child: Text(modeLabels[type] ?? type.toUpperCase(),
            style: const TextStyle(
                fontSize: 11, letterSpacing: 1.1, color: Colors.white70)),
      );

  Widget _alertBanner(String level, String msg) {
    final color = switch (level) {
      'danger' => _bad,
      'warn' => _warn,
      _ => _dim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(level == 'ok' ? Icons.info_outline : Icons.warning_amber_rounded,
            color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style:
                    TextStyle(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _cardFor(String name, Map<String, dynamic> s) {
    switch (name) {
      case 'fuel':
        return _fuelHero(s);
      case 'pit':
        return _pitCard(s);
      case 'pace':
        return _paceCard(s);
      case 'deg':
        return _degCard(s);
      case 'tyres':
        return _tyresCard(s);
      case 'timetrial':
        return _timeTrialHero(s);
      case 'test':
        return _testHero(s);
      default:
        return const SizedBox.shrink();
    }
  }

  // ---- LIVE telemetry (always visible) ------------------------------------
  Widget _liveTelemetry(Map<String, dynamic> s) {
    final lv = (s['live'] as Map?)?.cast<String, dynamic>() ?? const {};
    num n(String k) => (lv[k] as num?) ?? 0;
    final gear = (lv['gear'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('LIVE',
              style: TextStyle(
                  fontSize: 11, letterSpacing: 1.2, color: _dim)),
          const Spacer(),
          Text(gear > 0 ? 'G$gear' : 'N',
              style: const TextStyle(fontSize: 13, color: Colors.white70)),
        ]),
        const SizedBox(height: 8),
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${n('speed_kmh').round()}',
                  style: const TextStyle(
                      fontSize: 38, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              const Text('km/h',
                  style: TextStyle(color: _dim, fontSize: 14)),
              const Spacer(),
              Text('${n('rpm').round()} rpm',
                  style:
                      const TextStyle(fontSize: 13, color: Colors.white70)),
            ]),
        const SizedBox(height: 10),
        _bar('Throttle', n('throttle').toDouble(), 100, _ok),
        _bar('Brake', n('brake').toDouble(), 100, _bad),
        _bar('RPM', n('rpm').toDouble(), 8000, const Color(0xFF5AA9FF)),
        const SizedBox(height: 2),
        Row(children: [
          Text('boost ${n('boost')}',
              style: const TextStyle(color: _dim, fontSize: 12)),
          const Spacer(),
          Text(
              'water ${n('water_temp').round()}°  oil ${n('oil_temp').round()}°',
              style: const TextStyle(color: _dim, fontSize: 12)),
        ]),
      ]),
    );
  }

  Widget _bar(String label, double value, double maxV, Color color) {
    final frac = maxV <= 0 ? 0.0 : (value / maxV).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label, style: const TextStyle(fontSize: 12, color: _dim)),
          const Spacer(),
          Text(maxV == 100 ? '${value.round()}%' : value.round().toString(),
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: Colors.white10,
              color: color),
        ),
      ]),
    );
  }

  // ---- RACE: fuel hero (carries the race clock) ---------------------------
  Widget _fuelHero(Map<String, dynamic> s) {
    final balLaps = s['fuel_balance_laps'] as num?;
    final balColor = balLaps == null
        ? _dim
        : balLaps < 0
            ? _bad
            : balLaps < 0.5
                ? _warn
                : _ok;
    return _Card(
      title: 'FUEL · RACE',
      trailing: Text(
        '${s['time_remaining_str'] ?? '--:--'}  ·  LAP ${s['current_lap'] ?? 0}'
        '${s['laps_left_race'] != null ? '  ·  ~${s['laps_left_race']} to go' : ''}',
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _big(_num(s['fuel_laps_left'], dp: 1), unit: 'laps of fuel'),
        const SizedBox(height: 12),
        Row(children: [
          _Stat('In tank', '${_num(s['fuel_now_l'], dp: 1)} L'),
          _Stat('Per lap', '${_num(s['fuel_per_lap_l'], dp: 2)} L'),
          _Stat('Balance', '${_signed(s['fuel_balance_laps'], dp: 1)} laps',
              color: balColor),
          if (s['fuel_save_target_l'] != null)
            _Stat('Save to', '${_num(s['fuel_save_target_l'], dp: 2)} L/lap',
                color: _warn),
        ]),
      ]),
    );
  }

  Widget _pitCard(Map<String, dynamic> s) => _Card(
        title: 'PIT',
        child: Row(children: [
          _Stat('Stops left', '${s['stops_left'] ?? '—'}', size: 26),
          _Stat('Box by lap', '${s['pit_by_lap'] ?? '—'}', size: 26),
          _Stat('Refuel', '${_num(s['refuel_for_finish_l'], dp: 1)} L'),
          _Stat('Stop time', '${_num(s['refuel_time_s'], dp: 1)} s'),
        ]),
      );

  Widget _paceCard(Map<String, dynamic> s) => _Card(
        title: 'PACE',
        child: Row(children: [
          _Stat('Last', '${s['last_lap_str'] ?? '--:--.---'}', size: 22),
          _Stat('Best', '${s['best_lap_str'] ?? '--:--.---'}'),
          _Stat('Avg', '${s['avg_lap_str'] ?? '--:--.---'}'),
          _Stat('Δ best', _signed(s['last_delta_s'], dp: 3),
              color: _deltaColor(s['last_delta_s'])),
          _Stat('Speed', '${_round0(s['speed_kmh'])} km/h'),
        ]),
      );

  Widget _degCard(Map<String, dynamic> s) => _Card(
        title: 'TYRE DEG',
        child: Row(children: [
          _Stat('Deg', '${_signed(s['deg_per_lap_s'], dp: 3)} s/lap',
              color: _degColor(s['deg_per_lap_s']), size: 22),
          _Stat('Stint lap', '${s['stint_lap'] ?? 0}'),
          _Stat('Proj. end lap', '${s['proj_end_lap_str'] ?? '—'}'),
        ]),
      );

  Widget _tyresCard(Map<String, dynamic> s) {
    final t = (s['tyre_temps'] as Map?)?.cast<String, dynamic>() ?? const {};
    Widget tile(String label, dynamic temp) {
      final v = (temp as num?)?.toDouble();
      final c = v == null
          ? _dim
          : v > 110
              ? _bad
              : v > 95
                  ? _warn
                  : v >= 60
                      ? _ok
                      : const Color(0xFF5AA7E0);
      return Expanded(
        child: Container(
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
              color: c.withValues(alpha: 0.13),
              border: Border.all(color: c.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
            const SizedBox(height: 2),
            Text(v != null ? '${v.toStringAsFixed(0)}°' : '—',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: c)),
          ]),
        ),
      );
    }

    return _Card(
      title: 'TYRES',
      child: Column(children: [
        Row(children: [tile('FL', t['fl']), tile('FR', t['fr'])]),
        Row(children: [tile('RL', t['rl']), tile('RR', t['rr'])]),
      ]),
    );
  }

  Widget _timeTrialHero(Map<String, dynamic> s) {
    final ref = s['reference_lap_str'] as String? ?? 'no reference';
    final noRef = ref == 'no reference';
    return _Card(
      title: 'TIME TRIAL',
      trailing: _compoundChip(s['tire_compound'] as String?),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _big(_signed(s['delta_best_to_ref_s'], dp: 3),
            unit: 'best vs reference',
            color: _deltaColor(s['delta_best_to_ref_s'])),
        const SizedBox(height: 12),
        Row(children: [
          _Stat('Reference', ref),
          _Stat('Last vs ref', _signed(s['delta_last_to_ref_s'], dp: 3),
              color: _deltaColor(s['delta_last_to_ref_s'])),
        ]),
        if (noRef)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Set a reference lap under ⚙ Session settings.',
                style: TextStyle(color: _dim, fontSize: 12)),
          ),
      ]),
    );
  }

  Widget _testHero(Map<String, dynamic> s) => _Card(
        title: 'TEST RUN',
        trailing: _compoundChip(s['tire_compound'] as String?),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _big('${s['stint_done'] ?? 0} / ${s['stint_target'] ?? '—'}',
              unit: 'stint laps'),
          const SizedBox(height: 12),
          Row(children: [
            _Stat('Per lap', '${_num(s['fuel_per_lap_l'], dp: 2)} L'),
            _Stat('Range', '${_num(s['fuel_range_laps'], dp: 1)} laps'),
            _Stat('In tank', '${_num(s['fuel_now_l'], dp: 1)} L'),
          ]),
        ]),
      );

  Widget _compoundChip(String? c) => c == null
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.white10, borderRadius: BorderRadius.circular(8)),
          child: Text(c,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70)),
        );

  Widget _big(String value, {required String unit, Color? color}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(value,
            style: TextStyle(
                fontSize: 44,
                height: 1.0,
                fontWeight: FontWeight.w800,
                color: color ?? Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(unit,
              style: const TextStyle(color: _dim, fontSize: 13)),
        ),
      ]);

  Color _deltaColor(dynamic v) =>
      v == null ? _dim : ((v as num) <= 0 ? _ok : _bad);

  Color _degColor(dynamic v) {
    if (v == null) return _dim;
    final d = (v as num).toDouble();
    if (d > 0.15) return _bad;
    if (d > 0.05) return _warn;
    return _ok;
  }
}

// ---- formatting helpers (display only — never feeds parity math) ----------
String _num(dynamic v, {int dp = 1}) =>
    v == null ? '—' : (v as num).toStringAsFixed(dp);

String _signed(dynamic v, {int dp = 1}) {
  if (v == null) return '—';
  final d = (v as num).toDouble();
  return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(dp)}';
}

String _round0(dynamic v) => v == null ? '—' : (v as num).round().toString();

// ---- shared card chrome ----------------------------------------------------
class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Card({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                    color: _dim)),
            const Spacer(),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final double size;
  const _Stat(this.label, this.value, {this.color, this.size = 18});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w700,
                  color: color ?? Colors.white,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );
}

// ---- connection / first-run card -------------------------------------------
class _SetupCard extends StatefulWidget {
  final AppState state;
  const _SetupCard({required this.state});

  @override
  State<_SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<_SetupCard> {
  late final TextEditingController _ip =
      TextEditingController(text: widget.state.gt7Ip);

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    return _Card(
      title: 'CONNECTION',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          st.sourceError.isNotEmpty
              ? st.sourceError
              : 'Showing demo data. Put the PS5 on the same Wi-Fi with GT7 '
                  'open, then connect to go live.',
          style: TextStyle(
              color: st.sourceError.isNotEmpty ? _bad : Colors.white70,
              fontSize: 13),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: st.discovering ? null : st.discover,
          icon: st.discovering
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering),
          label: Text(st.discovering ? 'Searching…' : 'Find my PS5'),
        ),
        if (st.discoveryStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(st.discoveryStatus,
                style: const TextStyle(color: _dim, fontSize: 12)),
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _ip,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'or enter the IP, e.g. 192.168.1.40',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => st.setIp(v),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => st.setIp(_ip.text),
            child: const Text('Connect'),
          ),
        ]),
      ]),
    );
  }
}

// ---- radio ticker ------------------------------------------------------------
class _RadioTicker extends StatelessWidget {
  final List<CalloutLine> log;
  const _RadioTicker({required this.log});

  @override
  Widget build(BuildContext context) {
    final recent = log.reversed.take(5).toList();
    return _Card(
      title: 'RADIO',
      child: recent.isEmpty
          ? const Text('Quiet for now — calls land here and over TTS.',
              style: TextStyle(color: _dim, fontSize: 13))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < recent.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.headset_mic,
                              size: 14,
                              color: i == 0 ? _ok : Colors.white24),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(recent[i].text,
                                style: TextStyle(
                                    fontSize: i == 0 ? 15 : 13,
                                    fontWeight: i == 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: i == 0
                                        ? Colors.white
                                        : Colors.white54)),
                          ),
                        ]),
                  ),
              ],
            ),
    );
  }
}