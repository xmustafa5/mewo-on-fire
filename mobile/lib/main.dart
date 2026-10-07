import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'background.dart';
import 'ui/answer_screen.dart';
import 'ui/chat_screen.dart';
import 'ui/home_screen.dart';
import 'ui/theme/ember.dart';
import 'watch_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Port for TaskHandler -> UI messages.
  FlutterForegroundTask.initCommunicationPort();
  // Channel "ccnotify_service", ongoing "Listening for Claude Code sessions",
  // auto-run on boot, wifi lock.
  initForegroundTask();
  runApp(const MewoApp());
}

class MewoApp extends StatefulWidget {
  const MewoApp({super.key});

  @override
  State<MewoApp> createState() => _MewoAppState();
}

class _MewoAppState extends State<MewoApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    AppState.instance.openRequest.addListener(_onOpenRequest);
    AppState.instance.openSession.addListener(_onOpenSession);
    AppState.instance.init();
    WatchBridge.instance.init();
  }

  @override
  void dispose() {
    AppState.instance.openRequest.removeListener(_onOpenRequest);
    AppState.instance.openSession.removeListener(_onOpenSession);
    super.dispose();
  }

  /// An event notification was tapped: show that session's chat.
  void _onOpenSession() {
    final ref = AppState.instance.openSession.value;
    if (ref == null) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) {
      // Navigator not built yet (cold start): retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onOpenSession());
      return;
    }
    AppState.instance.openSession.value = null;
    nav.popUntil((r) => !ChatScreen.isChatRoute(r));
    nav.push(ChatScreen.route(ref.pcId, ref.sessionId));
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

  @override
  Widget build(BuildContext context) {
    final theme = emberTheme();
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Mewo on Fire',
      debugShowCheckedModeBanner: false,
      // Dark, always: the glow needs the dark.
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: ColoredBox(color: Ember.bg, child: child ?? const SizedBox.shrink()),
      ),
      home: const HomeScreen(),
    );
  }
}
