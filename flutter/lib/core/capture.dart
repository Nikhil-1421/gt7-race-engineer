/// Live PS5 capture — the Dart counterpart of `gt7dashboard.GT7Communication`
/// plus the lap normalisation `app/providers.RealProvider` performs.
///
/// Sends the one-byte 'A' heartbeat to <console>:33739 and receives encrypted
/// telemetry on UDP 33740 at ~60 Hz. Dart's RawDatagramSocket is event-driven,
/// so stopping is a clean `close()` — none of the blocked-recvfrom wake-packet
/// machinery the Python thread needed.
///
/// Lap semantics (mirrors the Python pipeline): when the in-race lap number
/// changes, the packet's `last_lap` field is the completed lap's time; fuel
/// consumed = fuel at lap start − fuel now. A non-positive consumption means
/// a refuel happened (pit lap) → the lap is an outlier and the stint counter
/// resets, exactly like RealProvider's normalisation.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';
import 'packet.dart';

class Gt7Capture {
  final String playstationIp;
  static const sendPort = 33739;
  static const receivePort = 33740;

  RawDatagramSocket? _sock;
  Timer? _hbTimer;
  final Stopwatch _clock = Stopwatch()..start();

  final StreamController<TelemetryFrame> _frames =
      StreamController.broadcast();
  Stream<TelemetryFrame> get frames => _frames.stream;

  TelemetryFrame last = const TelemetryFrame();
  final List<LapRecord> laps = [];

  double _lastDataAt = -1e9;
  int _packageId = 0;
  int _prevLap = -1;
  int _pktSinceHb = 0;
  double? _fuelAtLapStart;
  int _stintLap = 0;

  Gt7Capture(this.playstationIp);

  bool get isConnected =>
      _lastDataAt > 0 && (_now() - _lastDataAt) <= 1.0;

  double get lapElapsedS =>
      _prevLap > 0 ? (_now() - _lapStartAt).clamp(0.0, 1e9) : 0.0;
  double _lapStartAt = 0;

  double _now() => _clock.elapsedMicroseconds / 1e6;

  /// Bind and start. Throws a [SocketException] if 33740 is in use
  /// (e.g. another telemetry app is running).
  Future<void> start() async {
    final sock =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, receivePort);
    sock.broadcastEnabled = playstationIp == '255.255.255.255';
    _sock = sock;
    _sendHeartbeat();
    // Re-heartbeat if the stream goes quiet (console asleep / menu idle).
    _hbTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!isConnected) _sendHeartbeat();
    });
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      _onDatagram(Uint8List.fromList(dg.data));
    });
  }

  void stop() {
    _hbTimer?.cancel();
    _sock?.close();
    _sock = null;
    last = TelemetryFrame(
      connected: false,
      inRace: last.inRace,
      currentLap: last.currentLap,
    );
  }

  void _sendHeartbeat() {
    try {
      _sock?.send('A'.codeUnits, InternetAddress(playstationIp), sendPort);
    } on SocketException {
      // transient (interface flap); the periodic timer retries
    }
  }

  void _onDatagram(Uint8List data) {
    final pkt = decryptAndParse(data);
    if (pkt == null) return; // stray traffic / magic mismatch
    if (pkt.packageId <= _packageId) return; // stale or duplicate
    _packageId = pkt.packageId;
    _lastDataAt = _now();

    final f = pkt.frame;
    final cur = f.currentLap;

    if (cur > 0 && f.inRace) {
      if (cur != _prevLap) {
        if (_prevLap > 0) _finishLap(f); // uses the OLD lap's start fuel
        _prevLap = cur;
        _lapStartAt = _now();
        _fuelAtLapStart = f.currentFuel; // new lap's baseline
      }
    } else if (cur == 0) {
      // session reset (menus / restart)
      _prevLap = -1;
      _fuelAtLapStart = null;
      _stintLap = 0;
    }

    last = f;
    _frames.add(f);

    _pktSinceHb++;
    if (_pktSinceHb > 100) {
      _pktSinceHb = 0;
      _sendHeartbeat();
    }
  }

  void _finishLap(TelemetryFrame f) {
    final timeMs = f.lastLapMs;
    final consumed =
        _fuelAtLapStart != null ? _fuelAtLapStart! - f.currentFuel : -1.0;
    final outlier = consumed <= 0 || timeMs <= 0;
    _stintLap = outlier ? 1 : _stintLap + 1;
    laps.add(LapRecord(
      number: _prevLap,
      lapFinishTimeMs: timeMs,
      fuelConsumed: consumed > 0 ? consumed : 0.0,
      fuelAtEnd: f.currentFuel,
      stintLap: _stintLap,
      isOutlier: outlier,
    ));
  }

  void resetSession() {
    laps.clear();
    _prevLap = -1;
    _fuelAtLapStart = null;
    _stintLap = 0;
    _packageId = 0;
  }

  Future<void> dispose() async {
    stop();
    await _frames.close();
  }
}
