/// Application state — the Dart counterpart of the Python server's AppState
/// plus its compute loop, as a ChangeNotifier the UI rebuilds from.
///
/// Sources: a live [Gt7Capture] when an IP is configured, otherwise the
/// [DemoProvider] so the whole app is explorable with no console.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/analysis.dart';
import '../core/callouts.dart';
import '../core/capture.dart';
import '../core/catalog.dart';
import '../core/demo.dart';
import '../core/discovery.dart';
import '../core/engineer.dart';
import '../core/events.dart';
import '../core/model.dart';

class CalloutLine {
  final int id;
  final String text;
  final int priority;
  const CalloutLine(this.id, this.text, this.priority);
}

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;

  // source
  Gt7Capture? capture;
  DemoProvider? demo;
  String gt7Ip = '';
  String sourceError = '';

  // session
  EventConfig event = EventConfig.build(EventType.race);
  late SessionEngineer engineer = SessionEngineer(event);
  CalloutEngine callouts = CalloutEngine();
  ReferenceLap? reference;
  Catalog catalog = Catalog.empty();

  // outputs
  Map<String, dynamic> snapshot = const {'connected': false, 'in_race': false};
  final List<CalloutLine> calloutLog = [];
  int _calloutSeq = 0;
  bool ttsEnabled = false;
  void Function(String text)? onSpeak;

  // discovery
  bool discovering = false;
  String discoveryStatus = '';

  Timer? _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  double _lastTick = 0;
  double _simClock = 0;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    gt7Ip = _prefs?.getString('gt7_ip') ?? '';
    ttsEnabled = _prefs?.getBool('tts_enabled') ?? false;
    catalog = await Catalog.load();
    await _startSource();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  bool get synthetic => capture == null;

  Future<void> _startSource() async {
    capture?.stop();
    capture = null;
    demo = null;
    sourceError = '';
    if (gt7Ip.isNotEmpty) {
      final c = Gt7Capture(gt7Ip);
      try {
        await c.start();
        capture = c;
      } catch (e) {
        sourceError = 'Could not open UDP 33740 — is another telemetry '
            'app running? ($e)';
        demo = DemoProvider()..onPit = engineer.notifyPit;
      }
    } else {
      demo = DemoProvider()..onPit = engineer.notifyPit;
    }
    _simClock = 0;
    notifyListeners();
  }

  Future<void> setIp(String ip) async {
    gt7Ip = ip.trim();
    await _prefs?.setString('gt7_ip', gt7Ip);
    await _startSource();
  }

  Future<void> discover() async {
    if (discovering) return;
    discovering = true;
    discoveryStatus = 'Pinging the network for a console… (GT7 must be open)';
    notifyListeners();
    capture?.stop(); // free 33740 for the probe socket
    capture = null;
    final res = await discoverPs5();
    if (res.ip != null) {
      discoveryStatus = 'Found your PS5 at ${res.ip} — going live.';
      await setIp(res.ip!);
    } else {
      discoveryStatus = res.error == 'port_busy'
          ? 'Port 33740 is held by another app — close it and retry.'
          : 'No console answered. Same network? GT7 running? '
              'You can enter the IP manually.';
      await _startSource(); // restore previous source
    }
    discovering = false;
    notifyListeners();
  }

  void setEvent(String type, Map<String, Object?> values) {
    event = EventConfig.build(type, values);
    engineer = SessionEngineer(event, reference: reference);
    callouts = CalloutEngine();
    calloutLog.clear();
    if (demo != null) {
      demo = DemoProvider()..onPit = engineer.notifyPit;
      _simClock = 0;
    }
    notifyListeners();
  }

  /// Manual reference lap for time-trial mode ("1:34.500" or seconds).
  void setReferenceMs(int? ms) {
    reference = ms != null ? ReferenceLap(ms) : null;
    engineer = SessionEngineer(event, reference: reference);
    notifyListeners();
  }

  Future<void> setTts(bool on) async {
    ttsEnabled = on;
    await _prefs?.setBool('tts_enabled', on);
    notifyListeners();
  }

  void _tick() {
    final now = _clock.elapsedMicroseconds / 1e6;
    final dt = _lastTick == 0 ? 0.1 : now - _lastTick;
    _lastTick = now;
    _simClock += dt;

    TelemetryFrame tel;
    List<LapRecord> laps;
    if (capture != null) {
      tel = capture!.last;
      tel = TelemetryFrame(
        connected: capture!.isConnected,
        inRace: tel.inRace,
        isPaused: tel.isPaused,
        currentLap: tel.currentLap,
        totalLaps: tel.totalLaps,
        lastLapMs: tel.lastLapMs,
        bestLapMs: tel.bestLapMs,
        currentFuel: tel.currentFuel,
        fuelCapacity: tel.fuelCapacity,
        carSpeed: tel.carSpeed,
        throttle: tel.throttle,
        brake: tel.brake,
        tyreTempFl: tel.tyreTempFl,
        tyreTempFr: tel.tyreTempFr,
        tyreTempRl: tel.tyreTempRl,
        tyreTempRr: tel.tyreTempRr,
        rpm: tel.rpm,
        gear: tel.gear,
        boost: tel.boost,
        oilTemp: tel.oilTemp,
        waterTemp: tel.waterTemp,
      );
      laps = capture!.laps;
    } else {
      demo!.step(dt);
      tel = demo!.telemetry;
      laps = demo!.laps;
    }

    snapshot = engineer.snapshot(tel, laps, _simClock);
    snapshot['gt7_ip'] = gt7Ip;
    snapshot['synthetic'] = synthetic;
    snapshot['live'] = {
      'speed_kmh': tel.carSpeed.round(),
      'rpm': tel.rpm.round(),
      'gear': tel.gear,
      'throttle': tel.throttle.round(),
      'brake': tel.brake.round(),
      'boost': double.parse(tel.boost.toStringAsFixed(2)),
      'water_temp': tel.waterTemp.round(),
      'oil_temp': tel.oilTemp.round(),
    };

    for (final c in callouts.ingest(snapshot, _simClock)) {
      _calloutSeq++;
      calloutLog.add(CalloutLine(_calloutSeq, c.text, c.priority));
      if (ttsEnabled) onSpeak?.call(c.text);
    }
    if (calloutLog.length > 30) {
      calloutLog.removeRange(0, calloutLog.length - 30);
    }
    notifyListeners();
  }

  /// Comparison data for the Get Faster charts + Race Lines map — computed
  /// on-device from buffered lap traces, with the same shape as the server's
  /// /lap_trace endpoint (latest lap vs the fastest earlier lap).
  Map<String, dynamic> lapComparison() {
    final traces =
        capture?.lapTraces ?? demo?.lapTraces ?? const <LapTrace>[];
    if (traces.length < 2) {
      return {'available': false, 'reason': 'need at least 2 completed laps'};
    }
    final target = traces.last;
    LapTrace reference = traces.first;
    var best = double.infinity;
    for (var i = 0; i < traces.length - 1; i++) {
      final f = traces[i].tMs.isNotEmpty ? traces[i].tMs.last : double.infinity;
      if (f < best) {
        best = f;
        reference = traces[i];
      }
    }
    final data = comparisonTraces(target, reference);
    final rep = analyze(target, reference);
    data['total_delta_s'] = rep['total_delta_s'];
    data['improvements'] = rep['improvements'];
    return data;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    capture?.dispose();
    super.dispose();
  }
}