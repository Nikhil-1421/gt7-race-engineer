/// PS5 auto-discovery — the Dart counterpart of `app/discovery.py`.
///
/// Broadcasts the GT7 heartbeat and identifies the console from whichever
/// address replies on 33740. No decryption needed: any reply IS the PS5.
library;

import 'dart:async';
import 'dart:io';

import 'capture.dart';

class DiscoveryResult {
  final String? ip;
  final String? error; // 'port_busy' | 'not_found'
  const DiscoveryResult({this.ip, this.error});
}

Future<DiscoveryResult> discoverPs5({
  Duration timeout = const Duration(seconds: 6),
  bool sweep = true,
  List<String> extraTargets = const [],
}) async {
  RawDatagramSocket sock;
  try {
    sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, Gt7Capture.receivePort);
  } on SocketException {
    return const DiscoveryResult(error: 'port_busy');
  }
  sock.broadcastEnabled = true;

  final targets = <String>{'255.255.255.255', ...extraTargets};
  final locals = <String>[];
  try {
    for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final a in ni.addresses) {
        locals.add(a.address);
        final p = a.address.split('.');
        if (p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255');
      }
    }
  } catch (_) {}

  void send(Iterable<String> addrs) {
    for (final a in addrs) {
      try {
        sock.send('A'.codeUnits, InternetAddress(a), Gt7Capture.sendPort);
      } catch (_) {}
    }
  }

  final done = Completer<DiscoveryResult>();
  sock.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = sock.receive();
    if (dg == null || done.isCompleted) return;
    done.complete(DiscoveryResult(ip: dg.address.address));
  });

  send(targets);
  final hb = Timer.periodic(const Duration(milliseconds: 1200), (_) {
    send(targets);
  });
  Timer? sweepTimer;
  if (sweep) {
    sweepTimer = Timer(const Duration(milliseconds: 1500), () {
      // some routers filter broadcast between wifi/wired -> unicast the /24
      for (final ip in locals) {
        final p = ip.split('.');
        if (p.length != 4) continue;
        send([
          for (var h = 1; h < 255; h++)
            if ('${p[0]}.${p[1]}.${p[2]}.$h' != ip)
              '${p[0]}.${p[1]}.${p[2]}.$h'
        ]);
      }
    });
  }

  final res = await done.future
      .timeout(timeout, onTimeout: () => const DiscoveryResult(error: 'not_found'));
  hb.cancel();
  sweepTimer?.cancel();
  sock.close();
  return res;
}
