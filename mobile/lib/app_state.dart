import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;

import 'background.dart';
import 'models.dart';
import 'requests.dart';
import 'storage.dart';

/// A request to show on the answer screen.
class RequestRef {
  const RequestRef(this.pcId, this.requestId);
  final String pcId;
  final String requestId;
}

/// UI-isolate state. Only writer of `pcs` and `settings`; talks to the task
/// isolate via `{"cmd": ...}` messages and receives status / event / requests
/// messages. `pending_requests` is owned by the task: [requests] is a copy.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState._();
  static final AppState instance = AppState._();

  List<PairedPc> pcs = <PairedPc>[];
  AppSettings settings = const AppSettings();
  List<HistoryEntry> events = <HistoryEntry>[];
  Map<String, String> status = <String, String>{};

  /// Pending requests of all PCs, newest first.
  List<PendingRequest> requests = <PendingRequest>[];

  /// How recently resolved requests were resolved (`phone|pc|timeout`, or
  /// empty), by request key — lets an open answer screen say why it closes.
  final Map<String, String> resolvedBy = <String, String>{};

  /// Set when a request notification is tapped; the app shell opens the
  /// answer screen and resets it to null.
  final ValueNotifier<RequestRef?> openRequest = ValueNotifier<RequestRef?>(null);

  bool serviceRunning = false;
  bool loaded = false;
  bool _initStarted = false;
  bool _userStopped = false; // user pressed Stop: don't auto-restart on resume
  final fln.FlutterLocalNotificationsPlugin _notifs = fln.FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addObserver(this);
    try {
      // Same callbacks as the task isolate (see CcTaskHandler._initNotifications).
      await _notifs.initialize(
        settings: kNotificationInitSettings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: onNotificationResponseBackground,
      );
    } catch (e) {
      debugPrint('ccnotify: notifications init failed: $e');
    }
    try {
      pcs = await Store.loadPcs();
      settings = await Store.loadSettings();
      events = await Store.loadEvents();
      requests = await Store.loadPendingRequests();
    } catch (e) {
      debugPrint('ccnotify: loading state failed: $e');
    }
    serviceRunning = await _isRunning();
    loaded = true;
    notifyListeners();

    // Cold start from a tapped request notification.
    try {
      final launch = await _notifs.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch != null && launch.didNotificationLaunchApp && response != null) {
        _onNotificationResponse(response);
      }
    } catch (_) {}

    if (pcs.isNotEmpty && !serviceRunning) {
      await startService();
    } else if (serviceRunning) {
      _send('status');
    }
  }

  /// Taps on a notification while the app runs (and the cold-start tap).
  /// Action buttons normally go to [onNotificationResponseBackground]; they
  /// are handled here too in case a platform delivers them to the UI.
  void _onNotificationResponse(fln.NotificationResponse response) {
    final p = RequestPayload.tryParse(response.payload);
    if (p == null) return;
    final actionId = response.actionId;
    if (actionId != null && actionId.isNotEmpty) {
      final a = p.answerFor(actionId);
      if (a != null) unawaited(answer(p.pcId, p.requestId, a));
      return;
    }
    if (response.notificationResponseType == fln.NotificationResponseType.selectedNotification) {
      openRequest.value = RequestRef(p.pcId, p.requestId);
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

  static List<PendingRequest> _parseRequests(Object? list) {
    final out = <PendingRequest>[];
    if (list is! List) return out;
    for (final e in list) {
      if (e is! Map) continue;
      try {
        out.add(PendingRequest.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {}
    }
    return out;
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
    } else if (type == 'requests') {
      requests = _parseRequests(msg['requests']);
      notifyListeners();
    } else if (type == 'resolved') {
      final key = requestKey('${msg['pc_id']}', '${msg['request_id']}');
      resolvedBy[key] = msg['by'] is String ? msg['by'] as String : '';
      if (resolvedBy.length > 50) resolvedBy.remove(resolvedBy.keys.first);
      requests = requests.where((r) => r.key != key).toList();
      notifyListeners();
    }
  }

  // ---- requests (task owns `pending_requests`) ----

  /// Requests not answered from this phone yet (PCs tab badge).
  int get waitingCount => requests.where((r) => !r.answered).length;

  PendingRequest? findRequest(String pcId, String requestId) {
    final key = requestKey(pcId, requestId);
    for (final r in requests) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Sends [answer] for a request through the task isolate. When the service
  /// is not running, the answer is queued and the service started; the task
  /// sends it once the PC re-sends the request after connecting.
  Future<void> answer(String pcId, String requestId, Map<String, dynamic> answer) async {
    final key = requestKey(pcId, requestId);
    requests = [for (final r in requests) r.key == key && !r.answered ? r.withAnswer(answer) : r];
    notifyListeners();
    if (await _isRunning()) {
      try {
        FlutterForegroundTask.sendDataToTask(jsonEncode(answerMessage(pcId, requestId, answer)));
        return;
      } catch (e) {
        debugPrint('ccnotify: sending answer failed: $e');
      }
    }
    try {
      await Store.queueAnswer(pcId, requestId, answer);
      await _notifs.cancel(id: requestNotificationId(pcId, requestId));
    } catch (e) {
      debugPrint('ccnotify: queueing answer failed: $e');
    }
    if (pcs.isNotEmpty) await startService();
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
