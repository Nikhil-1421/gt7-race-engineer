/// GT7 packet parsing — the byte offsets documented by the gt7dashboard
/// community (see `gt7dashboard/gt7communication.py` GTData in the Python
/// repo). Parity-tested against ciphertexts decoded by that reference.
library;

import 'dart:typed_data';

import 'model.dart';
import 'salsa20.dart';

/// Everything we read out of one packet. [frame] is what the engineer
/// consumes; the rest is useful for capture bookkeeping and future UI.
class Gt7Packet {
  final TelemetryFrame frame;
  final int packageId;
  final int currentGear;
  final int suggestedGear;
  final int currentPosition; // only meaningful pre-race
  final int totalPositions;
  final double positionY;

  const Gt7Packet({
    required this.frame,
    required this.packageId,
    required this.currentGear,
    required this.suggestedGear,
    required this.currentPosition,
    required this.totalPositions,
    required this.positionY,
  });
}

/// Parse DECRYPTED packet bytes. Throws RangeError on truncated input.
Gt7Packet parsePacket(Uint8List plain) {
  final d = ByteData.sublistView(plain);
  double f32(int off) => d.getFloat32(off, Endian.little);
  int i32(int off) => d.getInt32(off, Endian.little);
  int i16(int off) => d.getInt16(off, Endian.little);
  int u8(int off) => d.getUint8(off);

  final flags = u8(0x8E);
  final gearByte = u8(0x90);

  final frame = TelemetryFrame(
    connected: true,
    inRace: (flags & 0x01) != 0,
    isPaused: (flags & 0x02) != 0,
    currentLap: i16(0x74),
    totalLaps: i16(0x76),
    bestLapMs: i32(0x78),
    lastLapMs: i32(0x7C),
    currentFuel: f32(0x44),
    fuelCapacity: f32(0x48),
    carSpeed: 3.6 * f32(0x4C), // stored as m/s
    throttle: u8(0x91) / 2.55,
    brake: u8(0x92) / 2.55,
    carId: i32(0x124),
    positionX: f32(0x04),
    positionZ: f32(0x0C),
    tyreTempFl: f32(0x60),
    tyreTempFr: f32(0x64),
    tyreTempRl: f32(0x68),
    tyreTempRr: f32(0x6C),
    rpm: f32(0x3C),
    gear: gearByte & 0x0F,
    boost: f32(0x50) - 1, // stored as pressure ratio; -1 → bar over atmospheric
    oilTemp: f32(0x5C),
    waterTemp: f32(0x58),
  );
  return Gt7Packet(
    frame: frame,
    packageId: i32(0x70),
    currentGear: gearByte & 0x0F,
    suggestedGear: gearByte >> 4,
    currentPosition: i16(0x84),
    totalPositions: i16(0x86),
    positionY: f32(0x08),
  );
}

/// Decrypt a raw datagram and parse it. Returns null when the magic check
/// fails (stray traffic / wake packets / truncation).
Gt7Packet? decryptAndParse(Uint8List datagram) {
  final plain = gt7Decrypt(datagram);
  if (plain == null || plain.length < 0x128) return null;
  return parsePacket(plain);
}