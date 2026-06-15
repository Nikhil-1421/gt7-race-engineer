import 'package:flutter_tts/flutter_tts.dart';

/// Serial text-to-speech queue. Radio lines never talk over each other:
/// each call waits for the previous utterance to finish, mirroring the
/// debounced single-line behaviour of the Python voice paths.
class TtsSpeaker {
  final FlutterTts _tts = FlutterTts();
  final List<String> _queue = [];
  bool _draining = false;
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.52);
      await _tts.setPitch(1.0);
    } catch (_) {
      // No TTS engine on this platform/run — speak() becomes a no-op below.
    }
  }

  void speak(String text) {
    _queue.add(text);
    _drain();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    await _configure();
    while (_queue.isNotEmpty) {
      final line = _queue.removeAt(0);
      try {
        await _tts.speak(line);
      } catch (_) {
        _queue.clear(); // engine unavailable — drop the backlog quietly
      }
    }
    _draining = false;
  }

  Future<void> dispose() async {
    _queue.clear();
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
