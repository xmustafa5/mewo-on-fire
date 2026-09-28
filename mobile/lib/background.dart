import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;

import 'models.dart';
import 'pc_link.dart';
import 'requests.dart';
import 'storage.dart';

const int kServiceId = 4782;
const String kServiceChannelId = 'ccnotify_service';
const String kServiceTitle = 'Listening for Claude Code sessions';
const String kNotifyIconMeta = 'com.torchcorp.ccnotify.NOTIFY_ICON';

// ---------------------------------------------------------------------------
// Service control (called from the UI isolate)
// ---------------------------------------------------------------------------

/// Configures the foreground service. Call once in main().
void initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: kServiceChannelId,
      channelName: 'Background connection',
      channelDescription: 'Shown while ccnotify keeps the connection to your PCs open.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // Used to detect network changes (see CcTaskHandler.onRepeatEvent).
      eventAction: ForegroundTaskEventAction.repeat(15000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Starts the foreground service if it is not running. Returns whether it runs.
Future<bool> startForegroundService() async {
  if (await FlutterForegroundTask.isRunningService) return true;
  final result = await FlutterForegroundTask.startService(
    serviceId: kServiceId,
    serviceTypes: const [ForegroundServiceTypes.connectedDevice],
    notificationTitle: kServiceTitle,
    notificationText: 'Connecting…',
    notificationIcon: const NotificationIcon(metaDataName: kNotifyIconMeta),
    callback: startCallback,
  );
  if (result is ServiceRequestFailure) {
    debugPrint('ccnotify: startService failed: ${result.error}');
  }
  return FlutterForegroundTask.isRunningService;
}

Future<void> stopForegroundService() async {
  await FlutterForegroundTask.stopService();
}

// ---------------------------------------------------------------------------
// Task isolate
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(CcTaskHandler());
}

const fln.AndroidNotificationChannel _chNeedsInput = fln.AndroidNotificationChannel(
  'needs_input',
  'Needs your input',
  description: 'Claude Code is waiting for you (permission prompt, question, idle).',
  importance: fln.Importance.high,
);

const fln.AndroidNotificationChannel _chStop = fln.AndroidNotificationChannel(
  'stop',
  'Finished',
  description: 'Claude Code finished a reply.',
  importance: fln.Importance.defaultImportance,
);

const fln.AndroidNotificationChannel _chSessionEnd = fln.AndroidNotificationChannel(
  'session_end',
  'Session closed',
  description: 'A Claude Code session ended.',
  importance: fln.Importance.low,
);

const fln.AndroidNotificationChannel _chRequests = fln.AndroidNotificationChannel(
  'requests',
  'Answer prompts',
  description: 'Claude Code asks for permission, has a question or wants a plan approved. '
      'Answer with the buttons.',
  importance: fln.Importance.max,
);

/// Requests older than this are dropped locally (the PC drops them at 24 h).
const Duration _requestMaxAge = Duration(hours: 25);

/// Stable, positive 31-bit notification id for [key] — FNV-1a.
int _stableId(String key) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(key)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  var id = h & 0x7fffffff;
  if (id == 0 || id == kServiceId) id += 1;
  return id;
}

/// Notification id per (pc, event).
int notificationIdFor(String pcId, int eventId) => _stableId('$pcId:$eventId');

/// Notification id per (pc, request).
int requestNotificationId(String pcId, String requestId) =>
    _stableId('req:${requestKey(pcId, requestId)}');

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

/// Owns all PC connections. Only writer of `events`, `since_<pcId>`,
/// `hosts_<pcId>`, `pending_requests`. Shows the system notifications and
/// sends answers (from the UI, action buttons and the `queued_answer_*` queue).
class CcTaskHandler extends TaskHandler {
  final fln.FlutterLocalNotificationsPlugin _notifs = fln.FlutterLocalNotificationsPlugin();
  final Map<String, PcLink> _links = <String, PcLink>{};
  final Map<String, String> _pcSig = <String, String>{};
  final Completer<void> _ready = Completer<void>();

  AppSettings _settings = const AppSettings();
  List<HistoryEntry> _events = <HistoryEntry>[];
  bool _notifsReady = false;

  /// Pending requests of all PCs, newest first (`pending_requests`).
  final List<PendingRequest> _requests = <PendingRequest>[];

  /// Request keys whose notification was shown during this run (dedupe of
  /// the requests the PC re-sends on every reconnect).
  final Set<String> _notified = <String>{};

  ReceivePort? _answerPort;
  bool _draining = false;

  Future<void> _reloadChain = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();
  Future<void> _requestsSaveChain = Future<void>.value();
  Timer? _saveTimer;
  String? _netSig;
  String _lastSummary = '';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _openAnswerPort();
    try {
      await _initNotifications();
    } catch (e) {
      debugPrint('ccnotify: notifications init failed: $e');
    }
    try {
      _events = await Store.loadEvents();
    } catch (_) {}
    try {
      _requests.addAll(await Store.loadPendingRequests());
    } catch (_) {}
    _pruneOldRequests();
    await _serialReload(cleanOrphans: true);
    _netSig = await _networkSignature();
    if (!_ready.isCompleted) _ready.complete();
    unawaited(_drainQueuedAnswers());

    if (_links.isEmpty) {
      // Nothing to listen to (e.g. started on boot after all PCs were removed).
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (!_ready.isCompleted) return;
    unawaited(_checkNetwork());
    unawaited(_drainQueuedAnswers());
    _pruneOldRequests();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _closeAnswerPort();
    _saveTimer?.cancel();
    _saveTimer = null;
    for (final l in _links.values) {
      await l.stop();
    }
    _links.clear();
    try {
      await _queueSave();
    } catch (_) {}
    try {
      await _requestsSaveChain;
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    final cmd = _decodeMap(data);
    if (cmd == null || cmd['cmd'] is! String) return;
    _ready.future.then((_) => _handleCmd(cmd));
  }

  // ---- commands from the UI ----

  static Map<String, dynamic>? _decodeMap(Object? data) {
    Object? d = data;
    if (d is String) {
      try {
        d = jsonDecode(d);
      } catch (_) {
        return null;
      }
    }
    if (d is Map) return Map<String, dynamic>.from(d);
    return null;
  }

  Future<void> _handleCmd(Map<String, dynamic> msg) async {
    final cmd = msg['cmd'];
    if (cmd == 'reload') {
      await _serialReload();
    } else if (cmd == 'clear_history') {
      _events = <HistoryEntry>[];
      _saveTimer?.cancel();
      _saveTimer = null;
      await _queueSave();
    } else if (cmd == 'reconnect') {
      _kickDisconnected();
      _sendStatus(force: true);
      _sendRequests();
    } else if (cmd == 'status') {
      _sendStatus(force: true);
      _sendRequests();
    } else if (cmd == 'answer') {
      await _handleAnswer(msg);
    }
  }

  // ---- answers (UI, action buttons, queue) ----

  /// Registers the port that action buttons send answers to (see
  /// `onNotificationResponseBackground`).
  void _openAnswerPort() {
    _closeAnswerPort();
    final port = ReceivePort();
    _answerPort = port;
    IsolateNameServer.removePortNameMapping(kAnswerPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, kAnswerPortName);
    port.listen((Object? data) {
      final msg = _decodeMap(data);
      if (msg == null) return;
      _ready.future.then((_) => _handleAnswer(msg));
    });
  }

  void _closeAnswerPort() {
    final port = _answerPort;
    _answerPort = null;
    if (port == null) return;
    IsolateNameServer.removePortNameMapping(kAnswerPortName);
    port.close();
  }

  /// Sends the answers queued while the task was not running.
  Future<void> _drainQueuedAnswers() async {
    if (_draining) return;
    _draining = true;
    try {
      final queued = await Store.takeQueuedAnswers();
      for (final m in queued) {
        await _handleAnswer(m);
      }
    } catch (e) {
      debugPrint('ccnotify: draining queued answers failed: $e');
    } finally {
      _draining = false;
    }
  }

  /// `{"pc_id", "request_id", "answer"}` → answer frame. If the PC is offline
  /// the answer stays on the request and is sent when the PC re-sends it.
  Future<void> _handleAnswer(Map<String, dynamic> msg) async {
    final pcId = _str(msg['pc_id']);
    final requestId = _str(msg['request_id']);
    final a = msg['answer'];
    if (pcId.isEmpty || requestId.isEmpty || a is! Map) return;
    final answer = Map<String, dynamic>.from(a);
    final key = requestKey(pcId, requestId);

    final i = _requests.indexWhere((r) => r.key == key);
    if (i >= 0) {
      if (_requests[i].answered) return; // first answer wins
      _requests[i] = _requests[i].withAnswer(answer);
      _saveRequests();
      _sendRequests();
    }
    await _cancelRequestNotification(pcId, requestId);
    // Unknown request (e.g. dropped locally): still send; the PC replies
    // `resolved` if it is finished.
    _links[pcId]?.sendAnswer(requestId, answer);
  }

  // ---- links ----

  Future<void> _serialReload({bool cleanOrphans = false}) {
    _reloadChain = _reloadChain
        .then((_) => _reload(cleanOrphans: cleanOrphans))
        .catchError((Object e) {
      debugPrint('ccnotify: reload failed: $e');
    });
    return _reloadChain;
  }

  Future<void> _reload({bool cleanOrphans = false}) async {
    final pcs = await Store.loadPcs();
    try {
      _settings = await Store.loadSettings();
    } catch (_) {}
    final ids = <String>{for (final p in pcs) p.id};

    for (final id in _links.keys.toList()) {
      if (!ids.contains(id)) {
        await _links.remove(id)!.stop();
        _pcSig.remove(id);
        try {
          await Store.removePcState(id);
        } catch (_) {}
      }
    }
    // Requests of PCs that are no longer paired can't be answered.
    await _dropRequests((r) => !ids.contains(r.pcId));
    if (cleanOrphans) {
      try {
        await Store.removeOrphanPcState(ids);
      } catch (_) {}
    }

    for (final pc in pcs) {
      final sig = jsonEncode(pc.toJson());
      final existing = _links[pc.id];
      if (existing != null && _pcSig[pc.id] == sig) continue;
      if (existing != null) {
        // Re-paired (new token / hosts): drop discovered hosts, restart link.
        await existing.stop();
        try {
          await Store.removeHosts(pc.id);
        } catch (_) {}
      }
      _pcSig[pc.id] = sig;
      final link = PcLink(
        pc: pc,
        onState: _onLinkState,
        onEvent: _onEvent,
        onRequest: _onRequest,
        onResolved: _onResolved,
        onRequestsSynced: _onRequestsSynced,
      );
      _links[pc.id] = link;
      link.start();
    }
    _sendStatus(force: true);
    _sendRequests();
  }

  void _onLinkState(PcLink link) {
    _sendStatus();
    if (link.state == PcStatus.unpaired) {
      // Revoked on the PC: its requests will never be resolved for us.
      final id = link.pc.id;
      unawaited(_dropRequests((r) => r.pcId == id));
    }
  }

  void _kickDisconnected() {
    for (final l in _links.values) {
      if (l.state != PcStatus.connected && l.state != PcStatus.unpaired) l.kick();
    }
  }

  Future<void> _checkNetwork() async {
    final sig = await _networkSignature();
    if (sig == _netSig) return;
    _netSig = sig;
    if (sig.isNotEmpty) _kickDisconnected();
  }

  static Future<String> _networkSignature() async {
    try {
      final ifs = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final parts = <String>[
        for (final i in ifs) '${i.name}=${i.addresses.map((a) => a.address).join(',')}',
      ]..sort();
      return parts.join(';');
    } catch (_) {
      return '';
    }
  }

  void _sendStatus({bool force = false}) {
    final map = <String, String>{for (final e in _links.entries) e.key: e.value.state};
    FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'status', 'pcs': map}));

    final total = map.length;
    final connected = map.values.where((s) => s == PcStatus.connected).length;
    final summary = total == 0
        ? 'No paired PCs'
        : 'Connected to $connected of $total PC${total == 1 ? '' : 's'}';
    if (summary != _lastSummary || force) {
      _lastSummary = summary;
      unawaited(FlutterForegroundTask.updateService(
        notificationTitle: kServiceTitle,
        notificationText: summary,
      ));
    }
  }

  // ---- events ----

  Future<void> _onEvent(PcLink link, CcEvent ev, bool live) async {
    final pc = link.pc;
    _events.insert(0, HistoryEntry(pcId: pc.id, pcName: pc.name, event: ev));
    if (_events.length > Store.maxEvents) {
      _events.removeRange(Store.maxEvents, _events.length);
    }
    _scheduleSave();

    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'event',
      'pc_id': pc.id,
      'pc_name': pc.name,
      'event': ev.toJson(),
    }));

    // Replayed events only notify if < 30 min old; live events always do.
    final fresh = DateTime.now().millisecondsSinceEpoch - ev.ts < 30 * 60 * 1000;
    if ((live || fresh) && _settings.allows(ev)) {
      try {
        await _notify(pc, ev);
      } catch (e) {
        debugPrint('ccnotify: notify failed: $e');
      }
    }
  }

  /// Throttled write of `events` (at most one write per 400 ms).
  void _scheduleSave() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveTimer = null;
      unawaited(_queueSave());
    });
  }

  Future<void> _queueSave() {
    final snapshot = List<HistoryEntry>.of(_events);
    _saveChain = _saveChain
        .then((_) => Store.saveEvents(snapshot))
        .catchError((Object e) {
      debugPrint('ccnotify: saving events failed: $e');
    });
    return _saveChain;
  }

  // ---- requests ----

  Future<void> _onRequest(PcLink link, CcRequest req) async {
    final pc = link.pc;
    final key = requestKey(pc.id, req.id);
    final i = _requests.indexWhere((r) => r.key == key);
    if (i >= 0) {
      // Re-sent on reconnect: already listed.
      final existing = _requests[i];
      if (existing.answered) {
        // Still pending on the PC → our answer may have been lost; resend.
        link.sendAnswer(req.id, existing.answer!);
        return;
      }
      if (_notified.contains(key)) return;
      // Loaded from prefs (e.g. after a reboot): show its notification again.
    } else {
      _requests.insert(0, PendingRequest(pcId: pc.id, pcName: pc.name, request: req));
      _saveRequests();
      _sendRequests();
    }
    if (!_settings.allowsRequest(req)) return;
    _notified.add(key);
    try {
      await _notifyRequest(pc, req);
    } catch (e) {
      debugPrint('ccnotify: request notify failed: $e');
    }
  }

  Future<void> _onResolved(PcLink link, String requestId, String by) async {
    final pcId = link.pc.id;
    await _dropRequests((r) => r.pcId == pcId && r.request.id == requestId, by: by);
    // Also when it wasn't listed (e.g. notification from a previous run).
    await _cancelRequestNotification(pcId, requestId);
  }

  /// [requestIds]: every request the PC sent within a few seconds after
  /// `hello`. Listed requests of that PC that were not re-sent were resolved
  /// while we were disconnected.
  Future<void> _onRequestsSynced(PcLink link, Set<String> requestIds) async {
    final pcId = link.pc.id;
    await _dropRequests((r) => r.pcId == pcId && !requestIds.contains(r.request.id));
  }

  void _pruneOldRequests() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _requestMaxAge.inMilliseconds;
    unawaited(_dropRequests((r) => r.request.ts > 0 && r.request.ts < cutoff));
  }

  /// Removes the matching requests, cancels their notifications and tells the
  /// UI (`resolved` with [by] = `phone|pc|timeout`, or empty when the request
  /// just disappeared).
  Future<void> _dropRequests(bool Function(PendingRequest r) test, {String by = ''}) async {
    final gone = _requests.where(test).toList();
    if (gone.isEmpty) return;
    _requests.removeWhere(test);
    _saveRequests();
    for (final r in gone) {
      _notified.remove(r.key);
      FlutterForegroundTask.sendDataToMain(jsonEncode({
        'type': 'resolved',
        'pc_id': r.pcId,
        'request_id': r.request.id,
        'by': by,
      }));
    }
    _sendRequests();
    for (final r in gone) {
      await _cancelRequestNotification(r.pcId, r.request.id);
    }
  }

  void _sendRequests() {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'requests',
      'requests': _requests.map((r) => r.toJson()).toList(),
    }));
  }

  /// Serialized write of `pending_requests` (requests are rare: no throttle).
  void _saveRequests() {
    final snapshot = List<PendingRequest>.of(_requests);
    _requestsSaveChain = _requestsSaveChain
        .then((_) => Store.savePendingRequests(snapshot))
        .catchError((Object e) {
      debugPrint('ccnotify: saving requests failed: $e');
    });
  }

  // ---- system notifications ----

  Future<void> _initNotifications() async {
    // Same callbacks as the UI isolate: whichever isolate initializes last
    // stores the background callback handle natively, so both must pass it.
    await _notifs.initialize(
      settings: kNotificationInitSettings,
      onDidReceiveNotificationResponse: onNotificationResponseBackground,
      onDidReceiveBackgroundNotificationResponse: onNotificationResponseBackground,
    );
    final android = _notifs.resolvePlatformSpecificImplementation<
        fln.AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(_chNeedsInput);
      await android.createNotificationChannel(_chStop);
      await android.createNotificationChannel(_chSessionEnd);
      await android.createNotificationChannel(_chRequests);
    }
    _notifsReady = true;
  }

  Future<void> _cancelRequestNotification(String pcId, String requestId) async {
    if (!_notifsReady) return;
    try {
      await _notifs.cancel(id: requestNotificationId(pcId, requestId));
    } catch (_) {}
  }

  Future<void> _notifyRequest(PairedPc pc, CcRequest r) async {
    if (!_notifsReady) return;
    final String emoji;
    switch (r.kind) {
      case RequestKind.question:
        emoji = '❓';
        break;
      case RequestKind.plan:
        emoji = '📋';
        break;
      default:
        emoji = '🔐';
    }
    final title = '$emoji ${r.project} · ${r.title.isEmpty ? 'Claude needs you' : r.title}';
    final body = r.summary;
    var big = r.detail.isNotEmpty ? r.detail : r.summary;
    if (big.length > 1500) big = '${big.substring(0, 1500)}…';
    final actions = <fln.AndroidNotificationAction>[
      for (final (id, label) in requestActions(r))
        fln.AndroidNotificationAction(
          id,
          label,
          showsUserInterface: false,
          cancelNotification: true,
        ),
    ];
    final details = fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        _chRequests.id,
        _chRequests.name,
        channelDescription: _chRequests.description,
        importance: fln.Importance.max,
        priority: fln.Priority.max,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        subText: pc.name,
        when: r.ts > 0 ? r.ts : null,
        showWhen: true,
        ticker: title,
        styleInformation: big.isEmpty ? null : fln.BigTextStyleInformation(big),
        actions: actions.isEmpty ? null : actions,
      ),
    );
    await _notifs.show(
      id: requestNotificationId(pc.id, r.id),
      title: title,
      body: body.isEmpty ? null : body,
      notificationDetails: details,
      payload: RequestPayload.forRequest(pc.id, r).encode(),
    );
  }

  Future<void> _notify(PairedPc pc, CcEvent ev) async {
    if (!_notifsReady) return;
    final fln.AndroidNotificationChannel ch;
    final fln.Priority priority;
    final String title;
    switch (ev.kind) {
      case EventKind.needsInput:
        ch = _chNeedsInput;
        priority = fln.Priority.high;
        title = '⏳ ${ev.project} needs input';
        break;
      case EventKind.stop:
        ch = _chStop;
        priority = fln.Priority.defaultPriority;
        title = '✅ ${ev.project} finished';
        break;
      case EventKind.sessionEnd:
        ch = _chSessionEnd;
        priority = fln.Priority.low;
        title = '⏹ ${ev.project} session closed';
        break;
      default:
        ch = _chStop;
        priority = fln.Priority.defaultPriority;
        title = '🔔 ${ev.project}: ${ev.kind}';
    }
    final body = ev.text;
    final details = fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        ch.id,
        ch.name,
        channelDescription: ch.description,
        importance: ch.importance,
        priority: priority,
        subText: pc.name,
        when: ev.ts,
        showWhen: true,
        ticker: title,
        styleInformation: body.isEmpty ? null : fln.BigTextStyleInformation(body),
      ),
    );
    await _notifs.show(
      id: notificationIdFor(pc.id, ev.id),
      title: title,
      body: body.isEmpty ? null : body,
      notificationDetails: details,
      payload: pc.id,
    );
  }
}
