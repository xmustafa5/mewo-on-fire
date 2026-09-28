import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'background.dart';
import 'ui/answer_screen.dart';
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
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    AppState.instance.openRequest.addListener(_onOpenRequest);
    AppState.instance.init();
  }

  @override
  void dispose() {
    AppState.instance.openRequest.removeListener(_onOpenRequest);
    super.dispose();
  }

  /// A request notification was tapped: show its answer screen.
  void _onOpenRequest() {
    final ref = AppState.instance.openRequest.value;
    if (ref == null) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) {
      // Navigator not built yet (cold start): retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onOpenRequest());
      return;
    }
    AppState.instance.openRequest.value = null;
    nav.popUntil((r) => !AnswerScreen.isAnswerRoute(r));
    nav.push(AnswerScreen.route(ref.pcId, ref.requestId));
  }

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kSeedColor, brightness: b),
        listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'ccnotify',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
