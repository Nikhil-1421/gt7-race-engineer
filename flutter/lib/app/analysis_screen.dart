/// Get Faster — the native counterpart of the web analysis view.
///
/// Reads [AppState.lapComparison] (computed on-device by the parity-locked
/// analysis core) and renders the delta / speed / throttle / brake charts plus
/// the Race Lines map, all keyed on one cumulative-distance grid so a single
/// cursor index links every chart and the map. Pure view layer.
library;

import 'package:flutter/material.dart';

import 'app_state.dart';

const _accent = Color(0xFF3DDC97);
const _danger = Color(0xFFFF4D5E);
const _blue = Color(0xFF5AA9FF);
const _warn = Color(0xFFFFB020);
const _dim = Color(0xFF5B6675);
const _dimText = Color(0xFF8B95A7);
const _panel = Color(0xFF0F131A);
const _surface = Color(0xFF191D21);

class AnalysisScreen extends StatefulWidget {
  final AppState state;

  /// Optional pre-computed comparison (a saved session). When null, the screen
  /// computes the live latest-vs-fastest comparison from [AppState].
  final Map<String, dynamic>? data;
  const AnalysisScreen({super.key, required this.state, this.data});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  Map<String, dynamic>? _data;
  final ValueNotifier<int?> _cursor = ValueNotifier<int?>(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      _cursor.value = null;
      _data = widget.data ?? widget.state.lapComparison();
    });
  }

  List<double> _arr(String k) =>
      ((_data?[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final available = d != null && d['available'] == true;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF14171A),
        title: Text(widget.data == null ? 'Get Faster' : 'Saved session',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          if (widget.data == null)
            IconButton(
              tooltip: 'Analyze last lap',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
        ],
      ),
      body: !available
          ? _empty(d)
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              children: [
                _summary(d),
                const SizedBox(height: 8),
                _readout(),
                const SizedBox(height: 8),
                _chartCard(),
                const SizedBox(height: 12),
                _mapCard(),
                const SizedBox(height: 12),
                _zonesCard(d),
              ],
            ),
    );
  }

  Widget _empty(Map<String, dynamic>? d) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.timeline, color: _dim, size: 40),
            const SizedBox(height: 12),
            Text(
              d?['reason'] as String? ?? 'Run two laps, then analyze.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _dimText),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Analyze last lap')),
          ]),
        ),
      );

  Widget _summary(Map<String, dynamic> d) {
    final delta = (d['total_delta_s'] as num?)?.toDouble() ?? 0;
    final col = delta > 0.05 ? _danger : (delta < -0.05 ? _accent : _dimText);
    return Row(children: [
      Expanded(
        child: Text('${d['target']} vs ${d['reference']}',
            style: const TextStyle(color: _dimText, fontSize: 13)),
      ),
      Text('${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(3)} s',
          style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 15)),
    ]);
  }

  // live readout of every channel at the cursor
  Widget _readout() {
    return ValueListenableBuilder<int?>(
      valueListenable: _cursor,
      builder: (_, idx, __) {
        final dist = _arr('dist_m');
        if (idx == null || dist.isEmpty) {
          return const Text('Drag across a chart or the map to inspect a point',
              style: TextStyle(color: _dim, fontSize: 12));
        }
        final i = idx.clamp(0, dist.length - 1);
        String v(String k, [String u = '']) {
          final a = _arr(k);
          return i < a.length ? '${a[i].toStringAsFixed(0)}$u' : '–';
        }
        final dl = _arr('delta_s');
        final dlv = i < dl.length ? dl[i] : 0.0;
        return Wrap(spacing: 14, runSpacing: 4, children: [
          _chip('${dist[i].toStringAsFixed(0)} m', _dimText),
          _chip('Δ ${dlv >= 0 ? '+' : ''}${dlv.toStringAsFixed(3)}s',
              dlv > 0 ? _danger : _accent),
          _chip('${v('t_speed')} km/h', _blue),
          _chip('thr ${v('t_throttle', '%')}', _accent),
          _chip('brk ${v('t_brake', '%')}', _danger),
        ]);
      },
    );
  }

  Widget _chip(String s, Color c) => Text(s,
      style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600));

  Widget _chartCard() {
    final dist = _arr('dist_m');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _chart('Δ time (s) — above 0 = slower', dist, [
          _Series(_arr('delta_s'), _warn, 2),
        ], height: 92, zero: true, symmetric: true),
        _chart('Speed km/h', dist, [
          _Series(_arr('r_speed'), _dim, 1),
          _Series(_arr('t_speed'), _blue, 2),
        ], height: 110),
        _chart('Throttle %', dist, [
          _Series(_arr('r_throttle'), _dim, 1),
          _Series(_arr('t_throttle'), _accent, 2),
        ], height: 70, min: 0, max: 100),
        _chart('Brake %', dist, [
          _Series(_arr('r_brake'), _dim, 1),
          _Series(_arr('t_brake'), _danger, 2),
        ], height: 70, min: 0, max: 100),
        const SizedBox(height: 6),
        const Text('━ your lap     ━ reference',
            style: TextStyle(color: _dim, fontSize: 11)),
      ]),
    );
  }

  Widget _chart(String label, List<double> dist, List<_Series> series,
      {required double height, double? min, double? max, bool zero = false, bool symmetric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) => _setCursorFromX(e.localPosition.dx, context.size?.width, dist.length),
          onHorizontalDragStart: (e) => _setCursorFromXBox(e.localPosition.dx, dist.length),
          onHorizontalDragUpdate: (e) => _setCursorFromXBox(e.localPosition.dx, dist.length),
          child: LayoutBuilder(builder: (_, box) {
            return ValueListenableBuilder<int?>(
              valueListenable: _cursor,
              builder: (_, idx, __) => CustomPaint(
                size: Size(box.maxWidth, height),
                painter: _ChartPainter(
                    dist: dist,
                    series: series,
                    min: min,
                    max: max,
                    zero: zero,
                    symmetric: symmetric,
                    label: label,
                    cursor: idx),
              ),
            );
          }),
        ),
      ),
    );
  }

  void _setCursorFromX(double dx, double? width, int n) {
    if (width == null || width <= 0 || n <= 1) return;
    _cursor.value = (dx / width * (n - 1)).round().clamp(0, n - 1);
  }

  // uses the chart's own box width via a render lookup at drag time
  void _setCursorFromXBox(double dx, int n) {
    final w = context.findRenderObject() is RenderBox
        ? (context.findRenderObject() as RenderBox).size.width - 24
        : null;
    _setCursorFromX(dx, w, n);
  }

  Widget _mapCard() {
    final x = _arr('line_x'), z = _arr('line_z');
    final thr = _arr('t_throttle'), brk = _arr('t_brake');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Race Lines',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SizedBox(
          height: 300,
          child: LayoutBuilder(builder: (_, box) {
            final size = Size(box.maxWidth, 300);
            final xf = _MapXform.fit(size, x, z);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (e) => _nearestOnMap(e.localPosition, xf, x, z),
              onPanStart: (e) => _nearestOnMap(e.localPosition, xf, x, z),
              onPanUpdate: (e) => _nearestOnMap(e.localPosition, xf, x, z),
              child: ValueListenableBuilder<int?>(
                valueListenable: _cursor,
                builder: (_, idx, __) => CustomPaint(
                  size: size,
                  painter: _MapPainter(
                      x: x, z: z, thr: thr, brk: brk, xf: xf, cursor: idx),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        const Text('━ throttle   ━ brake   ━ coasting · drag to scrub',
            style: TextStyle(color: _dim, fontSize: 11)),
      ]),
    );
  }

  void _nearestOnMap(Offset p, _MapXform xf, List<double> x, List<double> z) {
    if (x.isEmpty) return;
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < x.length; i++) {
      final dx = xf.px(x[i]) - p.dx, dy = xf.py(z[i]) - p.dy;
      final dd = dx * dx + dy * dy;
      if (dd < bd) {
        bd = dd;
        bi = i;
      }
    }
    _cursor.value = bi;
  }

  Widget _zonesCard(Map<String, dynamic> d) {
    final zones = (d['improvements'] as List?) ?? const [];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Where you're losing time",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (zones.isEmpty)
          const Text("No clear loss zones — you're matching the reference.",
              style: TextStyle(color: _dimText, fontSize: 13))
        else
          ...zones.asMap().entries.map((e) {
            final i = e.key;
            final z = (e.value as Map).cast<String, dynamic>();
            final notes = (z['notes'] as List?)?.cast<String>() ?? const [];
            final sector = z['sector'];
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(
                        '${i + 1}. ${(z['start_m'] as num).round()}–${(z['end_m'] as num).round()} m'
                        '${sector != null ? ' · S$sector' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  Text('−${(z['time_lost_s'] as num).toStringAsFixed(3)}s',
                      style: const TextStyle(color: _danger, fontSize: 13)),
                ]),
                ...notes.map((n) => Padding(
                      padding: const EdgeInsets.only(top: 2, left: 2),
                      child: Text('• $n',
                          style: const TextStyle(color: _dimText, fontSize: 12)),
                    )),
              ]),
            );
          }),
      ]),
    );
  }
}

class _Series {
  final List<double> data;
  final Color color;
  final double width;
  _Series(this.data, this.color, this.width);
}

class _ChartPainter extends CustomPainter {
  final List<double> dist;
  final List<_Series> series;
  final double? min, max;
  final bool zero, symmetric;
  final String label;
  final int? cursor;

  _ChartPainter({
    required this.dist,
    required this.series,
    required this.min,
    required this.max,
    required this.zero,
    required this.symmetric,
    required this.label,
    required this.cursor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bg = Paint()..color = _panel;
    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, h), const Radius.circular(8));
    canvas.drawRRect(r, bg);
    if (dist.isEmpty) return;
    final xmax = dist.last == 0 ? 1.0 : dist.last;

    double lo, hi;
    if (min != null && max != null) {
      lo = min!;
      hi = max!;
    } else {
      lo = double.infinity;
      hi = -double.infinity;
      for (final s in series) {
        for (final v in s.data) {
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
      }
      if (symmetric) {
        final m = (lo.abs() > hi.abs() ? lo.abs() : hi.abs());
        lo = -(m == 0 ? 1 : m);
        hi = (m == 0 ? 1 : m);
      }
      final pad = (hi - lo) * 0.08;
      lo -= pad == 0 ? 1 : pad;
      hi += pad == 0 ? 1 : pad;
    }
    double xp(double v) => v / xmax * (w - 6) + 3;
    double yp(double v) => h - 4 - (v - lo) / ((hi - lo) == 0 ? 1 : (hi - lo)) * (h - 8);

    if (zero) {
      final zl = Paint()
        ..color = const Color(0xFF26303D)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, yp(0)), Offset(w, yp(0)), zl);
    }
    for (final s in series) {
      if (s.data.isEmpty) continue;
      final p = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(xp(dist[0]), yp(s.data[0]));
      for (var i = 1; i < dist.length && i < s.data.length; i++) {
        path.lineTo(xp(dist[i]), yp(s.data[i]));
      }
      canvas.drawPath(path, p);
    }
    final tp = TextPainter(
      text: TextSpan(
          text: label, style: const TextStyle(color: Color(0xFF5B6675), fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(6, 4));

    if (cursor != null) {
      final i = cursor!.clamp(0, dist.length - 1);
      final cx = xp(dist[i]);
      final cl = Paint()
        ..color = Colors.white.withValues(alpha: 0.45)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), cl);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.cursor != cursor || old.series != series || old.dist != dist;
}

class _MapXform {
  final double minx, minz, scale, ox, oz, h;
  _MapXform(this.minx, this.minz, this.scale, this.ox, this.oz, this.h);

  factory _MapXform.fit(Size size, List<double> x, List<double> z) {
    if (x.isEmpty) return _MapXform(0, 0, 1, 0, 0, size.height);
    var minx = double.infinity, maxx = -double.infinity;
    var minz = double.infinity, maxz = -double.infinity;
    for (var i = 0; i < x.length; i++) {
      if (x[i] < minx) minx = x[i];
      if (x[i] > maxx) maxx = x[i];
      if (z[i] < minz) minz = z[i];
      if (z[i] > maxz) maxz = z[i];
    }
    const pad = 18.0;
    final sx = (size.width - 2 * pad) / ((maxx - minx) == 0 ? 1 : (maxx - minx));
    final sz = (size.height - 2 * pad) / ((maxz - minz) == 0 ? 1 : (maxz - minz));
    final s = sx < sz ? sx : sz;
    final ox = (size.width - (maxx - minx) * s) / 2;
    final oz = (size.height - (maxz - minz) * s) / 2;
    return _MapXform(minx, minz, s, ox, oz, size.height);
  }

  double px(double x) => ox + (x - minx) * scale;
  double py(double z) => h - (oz + (z - minz) * scale); // flip Z for screen
}

class _MapPainter extends CustomPainter {
  final List<double> x, z, thr, brk;
  final _MapXform xf;
  final int? cursor;
  _MapPainter({
    required this.x,
    required this.z,
    required this.thr,
    required this.brk,
    required this.xf,
    required this.cursor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = _panel;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, size.width, size.height),
            const Radius.circular(8)),
        bg);
    if (x.length < 2) return;
    for (var i = 1; i < x.length; i++) {
      final Color c = (i < thr.length && thr[i] > 50)
          ? _accent
          : (i < brk.length && brk[i] > 8)
              ? _danger
              : _dim;
      final p = Paint()
        ..color = c
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(xf.px(x[i - 1]), xf.py(z[i - 1])),
          Offset(xf.px(x[i]), xf.py(z[i])), p);
    }
    if (cursor != null) {
      final i = cursor!.clamp(0, x.length - 1);
      canvas.drawCircle(Offset(xf.px(x[i]), xf.py(z[i])), 5,
          Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.cursor != cursor || old.x != x;
}