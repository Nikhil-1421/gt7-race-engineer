import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/home_screen.dart';
import 'app/tts_speaker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  final tts = TtsSpeaker();
  state.onSpeak = tts.speak;
  await state.init();
  runApp(EngineerApp(state: state));
}

class EngineerApp extends StatelessWidget {
  final AppState state;
  const EngineerApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GT7 Race Engineer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE10600),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1113),
      ),
      home: HomeScreen(state: state),
    );
  }
}
