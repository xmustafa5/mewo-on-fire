import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'background.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Port for TaskHandler -> UI messages.
  FlutterForegroundTask.initCommunicationPort();
  // Channel "ccnotify_service", ongoing "Listening for Claude Code sessions",
  // auto-run on boot, wifi lock.
  initForegroundTask();
  runApp(const CcNotifyApp());
}

/// Claude-ish terracotta.
const Color kSeedColor = Color(0xFFD97757);

class CcNotifyApp extends StatefulWidget {
  const CcNotifyApp({super.key});

  @override
  State<CcNotifyApp> createState() => _CcNotifyAppState();
}

class _CcNotifyAppState extends State<CcNotifyApp> {
  @override
  void initState() {
    super.initState();
    AppState.instance.init();
  }

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kSeedColor, brightness: b),
        listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ccnotify',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
