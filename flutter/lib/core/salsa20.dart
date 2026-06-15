/// Salsa20 stream cipher + the GT7 packet decryption scheme.
///
/// Pure Dart, no dependencies. This is a line-for-line transliteration of
/// the Python reference in `tools/gen_parity_vectors.py`, which is itself
/// asserted against pycryptodome — and this file is replayed against the
/// same keystream vectors by `tool/parity/run_parity.dart`.
///
/// Dart ints are 64-bit, so every 32-bit add/shift is masked explicitly.
library;

import 'dart:typed_data';

const _mask = 0xFFFFFFFF;

int _rotl(int x, int n) {
  x &= _mask;
  return ((x << n) & _mask) | (x >> (32 - n));
}

void _quarter(List<int> s, int a, int b, int c, int d) {
  s[b] ^= _rotl(s[a] + s[d], 7);
  s[c] ^= _rotl(s[b] + s[a], 9);
  s[d] ^= _rotl(s[c] + s[b], 13);
  s[a] ^= _rotl(s[d] + s[c], 18);
}

/// One 64-byte Salsa20 keystream block (20 rounds).
Uint8List salsa20Block(Uint8List key32, Uint8List nonce8, int counter) {
  final kd = ByteData.sublistView(key32);
  final nd = ByteData.sublistView(nonce8);
  final k = List<int>.generate(8, (i) => kd.getUint32(i * 4, Endian.little));
  final n = List<int>.generate(2, (i) => nd.getUint32(i * 4, Endian.little));
  final c0 = counter & _mask;
  final c1 = (counter >> 32) & _mask;
  const sig = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]; // "expand 32-byte k"
  final init = <int>[
    sig[0], k[0], k[1], k[2], k[3], sig[1], n[0], n[1],
    c0, c1, sig[2], k[4], k[5], k[6], k[7], sig[3],
  ];
  final s = List<int>.from(init);
  for (var r = 0; r < 10; r++) {
    // column round
    _quarter(s, 0, 4, 8, 12);
    _quarter(s, 5, 9, 13, 1);
    _quarter(s, 10, 14, 2, 6);
    _quarter(s, 15, 3, 7, 11);
    // row round
    _quarter(s, 0, 1, 2, 3);
    _quarter(s, 5, 6, 7, 4);
    _quarter(s, 10, 11, 8, 9);
    _quarter(s, 15, 12, 13, 14);
  }
  final out = Uint8List(64);
  final od = ByteData.sublistView(out);
  for (var i = 0; i < 16; i++) {
    od.setUint32(i * 4, (s[i] + init[i]) & _mask, Endian.little);
  }
  return out;
}

/// XOR [data] with the Salsa20 keystream (encrypt == decrypt).
Uint8List salsa20Xor(Uint8List key32, Uint8List nonce8, Uint8List data) {
  final out = Uint8List(data.length);
  final blocks = (data.length + 63) ~/ 64;
  for (var blk = 0; blk < blocks; blk++) {
    final ks = salsa20Block(key32, nonce8, blk);
    final start = blk * 64;
    final end = (start + 64 < data.length) ? start + 64 : data.length;
    for (var i = start; i < end; i++) {
      out[i] = data[i] ^ ks[i - start];
    }
  }
  return out;
}

// ----------------------------------------------------------- GT7 scheme

/// First 32 bytes of "Simulator Interface Packet GT7 ver 0.0".
final Uint8List gt7Key = Uint8List.fromList(
  'Simulator Interface Packet GT7 ver 0.0'.codeUnits.sublist(0, 32),
);

const gt7Magic = 0x47375330;

/// Nonce derivation: iv1 read from ciphertext[0x40:0x44] (LE);
/// nonce = LE(iv1 ^ 0xDEADBEAF) ++ LE(iv1). Yes, BEAF — not a typo here,
/// it's the constant the game actually uses.
Uint8List gt7Nonce(int iv1) {
  final iv2 = (iv1 ^ 0xDEADBEAF) & _mask;
  final n = Uint8List(8);
  final d = ByteData.sublistView(n);
  d.setUint32(0, iv2, Endian.little);
  d.setUint32(4, iv1 & _mask, Endian.little);
  return n;
}

/// Decrypt a raw GT7 telemetry datagram. Returns the plaintext, or null if
/// the magic check fails (wrong key, truncated packet, or stray traffic).
Uint8List? gt7Decrypt(Uint8List datagram) {
  if (datagram.length < 0x44) return null;
  final iv1 =
      ByteData.sublistView(datagram).getUint32(0x40, Endian.little);
  final plain = salsa20Xor(gt7Key, gt7Nonce(iv1), datagram);
  final magic = ByteData.sublistView(plain).getUint32(0, Endian.little);
  if (magic != gt7Magic) return null;
  return plain;
}
