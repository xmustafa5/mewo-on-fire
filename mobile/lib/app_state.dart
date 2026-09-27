import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background.dart';
import 'models.dart';
import 'storage.dart';

/// UI-isolate state. Only writer of `pcs` and `settings`; talks to the task
/// isolate via `{"cmd": ...}` messages and receives status / event messages.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState._();
  static final AppState instance = AppState._();

  List<PairedPc> pcs = <PairedPc>[];
  AppSettings settings = const AppSettings();
  List<HistoryEntry> events = <HistoryEntry>[];
  Map<String, String> status = <String, String>{};
  bool serviceRunning = false;
  bool loaded = false;
  bool _initStarted = false;
  bool _userStopped = false; // user pressed Stop: don't auto-restart on resume

  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addObserver(this);
    try {
      pcs = await Store.loadPcs();
      settings = await Store.loadSettings();
      events = await Store.loadEvents();
    } catch (e) {
      debugPrint('ccnotify: loading state failed: $e');
    }
    serviceRunning = await _isRunning();
    loaded = true;
    notifyListeners();

    if (pcs.isNotEmpty && !serviceRunning) {
      await startService();
    } else if (serviceRunning) {
      _send('status');
    }
  }

  /// First launch: notification permission + battery-optimization exemption.
  /// Later launches only re-check the notification permission.
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final first = !(await Store.firstLaunchDone());
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (first && Platform.isAndroid) {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      }
      if (first) await Store.setFirstLaunchDone();
    } catch (e) {
      debugPrint('ccnotify: permission request failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onResume());
  }

  Future<void> _onResume() async {
    serviceRunning = await _isRunning();
    notifyListeners();
    if (serviceRunning) {
      _send('reconnect'); // PROTOCOL: reconnect immediately on app resume
    } else if (pcs.isNotEmpty && !_userStopped) {
      await startService();
    }
  }

  Future<bool> _isRunning() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  void _send(String cmd) {
    try {
      FlutterForegroundTask.sendDataToTask(jsonEncode({'cmd': cmd}));
    } catch (e) {
      debugPrint('ccnotify: sendDataToTask($cmd) failed: $e');
    }
  }

  void _onTaskData(Object data) {
    Map<String, dynamic>? msg;
    try {
      final Object? d = data is String ? jsonDecode(data) : data;
      if (d is Map) msg = Map<String, dynamic>.from(d);
    } catch (_) {}
    if (msg == null) return;

    final type = msg['type'];
    if (type == 'status') {
      final p = msg['pcs'];
      if (p is Map) {
        status = <String, String>{for (final e in p.entries) '${e.key}': '${e.value}'};
        serviceRunning = true;
        notifyListeners();
      }
    } else if (type == 'event') {
      final e = msg['event'];
      if (e is! Map) return;
      final ev = CcEvent.fromJson(Map<String, dynamic>.from(e));
      final pcId = '${msg['pc_id']}';
      if (events.any((h) => h.pcId == pcId && h.event.id == ev.id)) return;
      final pcName = msg['pc_name'] is String ? msg['pc_name'] as String : pcNameFor(pcId);
      events.insert(0, HistoryEntry(pcId: pcId, pcName: pcName, event: ev));
      if (events.length > Store.maxEvents) {
        events.removeRange(Store.maxEvents, events.length);
      }
      notifyListeners();
    }
  }

  String pcNameFor(String pcId) {
    for (final p in pcs) {
      if (p.id == pcId) return p.name;
    }
    return pcId;
  }

  /// Status shown in the UI for [pcId].
  String statusOf(String pcId) {
    if (!serviceRunning) return PcStatus.offline;
    return status[pcId] ?? PcStatus.connecting;
  }

  // ---- service ----

  Future<void> startService() async {
    _userStopped = false;
    serviceRunning = await startForegroundService();
    notifyListeners();
  }

  Future<void> stopService({bool byUser = false}) async {
    if (byUser) _userStopped = true;
    try {
      await stopForegroundService();
    } catch (_) {}
    serviceRunning = await _isRunning();
    if (!serviceRunning) status = <String, String>{};
    notifyListeners();
  }

  // ---- pcs (UI is the only writer) ----

  Future<void> addPc(PairedPc pc) async {
    pcs = <PairedPc>[...pcs.where((p) => p.id != pc.id), pc];
    await Store.savePcs(pcs);
    status[pc.id] = PcStatus.connecting;
    notifyListeners();
    if (await _isRunning()) {
      _send('reload');
    } else {
      await startService();
    }
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {}
  }

  Future<void> removePc(String id) async {
    pcs = pcs.where((p) => p.id != id).toList();
    await Store.savePcs(pcs);
    status.remove(id);
    notifyListeners();
    if (!await _isRunning()) return;
    _send('reload'); // task drops the link and its since_/hosts_ keys
    if (pcs.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await stopService();
    }
  }

  // ---- settings (UI is the only writer) ----

  Future<void> updateSettings(AppSettings s) async {
    settings = s;
    notifyListeners();
    await Store.saveSettings(s);
    _send('reload');
  }

  Future<void> muteProject(String project) async {
    if (settings.mutedProjects.contains(project)) return;
    await updateSettings(
        settings.copyWith(mutedProjects: <String>[...settings.mutedProjects, project]..sort()));
  }

  Future<void> unmuteProject(String project) async {
    await updateSettings(settings.copyWith(
        mutedProjects: settings.mutedProjects.where((p) => p != project).toList()));
  }

  // ---- history (task owns `events`) ----

  Future<void> clearHistory() async {
    events = <HistoryEntry>[];
    notifyListeners();
    if (await _isRunning()) {
      _send('clear_history');
    } else {
      // Task not running → no concurrent writer, safe to clear directly.
      await Store.saveEvents(<HistoryEntry>[]);
    }
  }
}
