/// Session history — browse saved sessions and re-open their lap comparison.
///
/// Reads the on-device store in [AppState]; opening a session pushes the same
/// [AnalysisScreen] used live, fed the saved (parity-locked) comparison.
library;

import 'package:flutter/material.dart';

import '../core/model.dart';
import 'analysis_screen.dart';
import 'app_state.dart';

const _danger = Color(0xFFFF4D5E);
const _dimText = Color(0xFF8B95A7);
const _surface = Color(0xFF191D21);

class HistoryScreen extends StatefulWidget {
  final AppState state;
  const HistoryScreen({super.key, required this.state});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _status = '';
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final rec = await widget.state.saveSession();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _status = rec == null
          ? 'No completed laps to save yet.'
          : 'Saved ${rec['track']} — ${rec['total_laps']} laps';
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.state.sessionSummaries();
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF14171A),
        title: const Text('Session history',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_alt, size: 18),
            label: Text(_saving ? 'Saving…' : 'Save current session'),
          ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status,
                  style: const TextStyle(color: _dimText, fontSize: 12)),
            ),
          const SizedBox(height: 14),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('No saved sessions yet. Finish a session and tap Save.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _dimText)),
            )
          else
            ...sessions.map(_card),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> s) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        ((s['saved_at'] as num) * 1000).toInt());
    final when =
        '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final hasAnalysis = s['has_analysis'] == true;
    final id = s['id'] as String;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
                '${s['track'] ?? 'Unknown'} · ${(s['event_type'] ?? 'race').toString().replaceAll('_', ' ')}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text(when, style: const TextStyle(color: _dimText, fontSize: 12)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
                '${s['total_laps']} laps · best ${fmtMs((s['best_lap_ms'] as num?)?.toInt())}',
                style: const TextStyle(color: _dimText, fontSize: 13)),
          ),
          if (hasAnalysis)
            TextButton(
              onPressed: () {
                final rec = widget.state.sessionRecord(id);
                final comp = rec?['comparison'] as Map<String, dynamic>?;
                if (comp != null) {
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) =>
                        AnalysisScreen(state: widget.state, data: comp),
                  ));
                }
              },
              child: const Text('Open'),
            )
          else
            const Text('no analysis',
                style: TextStyle(color: _dimText, fontSize: 12)),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.close, size: 18, color: _danger),
            onPressed: () async {
              await widget.state.deleteSession(id);
              if (mounted) setState(() {});
            },
          ),
        ]),
      ]),
    );
  }
}