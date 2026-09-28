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
import 'sessions.dart';
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

const fln.AndroidNotificationChannel _chStop = kStopChannel;

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

/// How long a message waits for its PC to connect before it is given up.
const Duration _sendConnectTimeout = Duration(seconds: 60);

/// How long a sent message waits for its `send_result`.
const Duration _sendResultTimeout = Duration(seconds: 20);

/// A `send` the task is handling: waiting for the PC to connect (`!sent`) or
/// for its `send_result`.
class _Outgoing {
  _Outgoing({
    required this.pcId,
    required this.sessionId,
    required this.text,
    required this.clientId,
    this.notif,
  });

  final String pcId;
  final String sessionId;
  final String text;
  final String clientId;
  final ReplyNotif? notif; // set when typed into a notification (Reply)
  bool sent = false;
  Timer? timer;
}

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
/// `hosts_<pcId>`, `pending_requests`, `sessions_cache`. Shows the system
/// notifications and sends answers and session messages (from the UI, action
/// buttons / Reply and the `queued_answer_*` / `queued_send_*` queues).
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

  /// Sessions of all PCs, newest first (`sessions_cache`).
  final List<SessionEntry> _sessions = <SessionEntry>[];

  /// Messages being sent, by client id.
  final Map<String, _Outgoing> _outbox = <String, _Outgoing>{};

  ReceivePort? _answerPort;
  bool _draining = false;

  Future<void> _reloadChain = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();
  Future<void> _requestsSaveChain = Future<void>.value();
  Future<void> _sessionsSaveChain = Future<void>.value();
  Timer? _saveTimer;
  Timer? _sessionsSaveTimer;
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
    try {
      _sessions.addAll(await Store.loadSessions());
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
    final sessionsDirty = _sessionsSaveTimer?.isActive ?? false;
    _sessionsSaveTimer?.cancel();
    _sessionsSaveTimer = null;
    for (final o in _outbox.values) {
      o.timer?.cancel();
    }
    _outbox.clear();
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
    try {
      if (sessionsDirty) await _queueSessionsSave();
      await _sessionsSaveChain;
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
      _sendSessions();
    } else if (cmd == 'status') {
      _sendStatus(force: true);
      _sendRequests();
      _sendSessions();
    } else if (cmd == 'answer') {
      await _handleAnswer(msg);
    } else if (cmd == 'send') {
      await _handleSend(msg);
    } else if (cmd == 'get_chat') {
      _handleGetChat(msg);
    } else if (cmd == 'refresh_sessions') {
      _handleRefreshSessions();
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
      _ready.future.then((_) => msg['cmd'] == 'send' ? _handleSend(msg) : _handleAnswer(msg));
    });
  }

  void _closeAnswerPort() {
    final port = _answerPort;
    _answerPort = null;
    if (port == null) return;
    IsolateNameServer.removePortNameMapping(kAnswerPortName);
    port.close();
  }

  /// Sends the answers and messages queued while the task was not running.
  Future<void> _drainQueuedAnswers() async {
    if (_draining) return;
    _draining = true;
    try {
      final queued = await Store.takeQueuedAnswers();
      for (final m in queued) {
        await _handleAnswer(m);
      }
      final sends = await Store.takeQueuedSends();
      for (final m in sends) {
        await _handleSend(m);
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

  // ---- sessions: chat + messages from the phone (v1.2) ----

  /// `{"pc_id", "session_id", "text", "client_id", "notif"?}` → `send` frame.
  /// Waits up to 60 s for the PC to connect; the result goes to the UI
  /// (`send_result`) and, for a Reply, onto its notification.
  Future<void> _handleSend(Map<String, dynamic> msg) async {
    final pcId = _str(msg['pc_id']);
    final sessionId = _str(msg['session_id']);
    if (pcId.isEmpty || sessionId.isEmpty) return;
    var clientId = _str(msg['client_id']);
    if (clientId.isEmpty) clientId = newClientId();
    if (_outbox.containsKey(clientId)) return; // duplicate
    final o = _Outgoing(
      pcId: pcId,
      sessionId: sessionId,
      text: _str(msg['text']).trim(),
      clientId: clientId,
      notif: ReplyNotif.fromJson(msg['notif']),
    );
    if (o.text.isEmpty) {
      await _finishSend(o, SendStatus.rejected, 'The message was empty');
      return;
    }
    final link = _links[pcId];
    if (link == null) {
      await _finishSend(o, SendStatus.rejected, 'This PC is no longer paired');
      return;
    }
    _outbox[clientId] = o;
    if (o.notif != null) await _updateReplyNotification(o, SendStatus.sending, '');
    _trySend(o, link);
    if (!o.sent) {
      link.kick();
      o.timer = Timer(_sendConnectTimeout, () {
        if (!o.sent) unawaited(_finishSend(o, SendStatus.rejected, '${link.pc.name} is offline'));
      });
    }
  }

  void _trySend(_Outgoing o, PcLink link) {
    if (o.sent || !link.sendMessage(o.sessionId, o.text, o.clientId)) return;
    o.sent = true;
    o.timer?.cancel();
    o.timer = Timer(_sendResultTimeout, () {
      unawaited(_finishSend(o, SendStatus.rejected,
          'No answer from ${link.pc.name} — is ccnotify up to date on the PC?'));
    });
  }

  /// Sends the messages that waited for [link] to connect.
  void _flushOutbox(PcLink link) {
    for (final o in _outbox.values.toList()) {
      if (o.pcId == link.pc.id && !o.sent) _trySend(o, link);
    }
  }

  Future<void> _onSendResult(PcLink link, String clientId, String status, String reason) async {
    final o = _outbox[clientId];
    if (o == null || o.pcId != link.pc.id) {
      // Unknown (e.g. after a timeout): still tell the UI.
      _sendSendResult(link.pc.id, '', clientId, status, reason);
      return;
    }
    await _finishSend(o, status, reason);
  }

  Future<void> _finishSend(_Outgoing o, String status, String reason) async {
    o.timer?.cancel();
    o.timer = null;
    _outbox.remove(o.clientId);
    _sendSendResult(o.pcId, o.sessionId, o.clientId, status, reason);
    if (o.notif != null) await _updateReplyNotification(o, status, reason);
  }

  void _sendSendResult(String pcId, String sessionId, String clientId, String status, String reason) {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'send_result',
      'pc_id': pcId,
      'session_id': sessionId,
      'client_id': clientId,
      'status': status,
      'reason': reason,
    }));
  }

  Future<void> _updateReplyNotification(_Outgoing o, String status, String reason) async {
    final notif = o.notif;
    if (notif == null || !_notifsReady) return;
    try {
      await showReplyStatus(
        _notifs,
        pcId: o.pcId,
        sessionId: o.sessionId,
        notif: notif,
        body: replyStatusText(status, o.text, reason),
        allowReply: status == SendStatus.delivered || status == SendStatus.queued,
      );
    } catch (e) {
      debugPrint('ccnotify: updating reply notification failed: $e');
    }
  }

  /// `{"pc_id", "session_id"}` → `get_chat`; the reply is forwarded as
  /// `chat`, or `chat_error` right away when the PC is not connected.
  void _handleGetChat(Map<String, dynamic> msg) {
    final pcId = _str(msg['pc_id']);
    final sessionId = _str(msg['session_id']);
    if (pcId.isEmpty || sessionId.isEmpty) return;
    final link = _links[pcId];
    String error = '';
    if (link == null) {
      error = 'This PC is no longer paired';
    } else if (!link.getChat(sessionId)) {
      link.kick();
      error = '${link.pc.name} is offline';
    }
    if (error.isEmpty) return;
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'chat_error',
      'pc_id': pcId,
      'session_id': sessionId,
      'error': error,
    }));
  }

  Future<void> _onChat(PcLink link, Map<String, dynamic> chat) async {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'chat',
      'pc_id': link.pc.id,
      'session_id': chat['session_id'],
      'title': chat['title'] is String ? chat['title'] : '',
      'items': chat['items'] is List ? chat['items'] : <Object?>[],
    }));
  }

  /// Asks every connected PC for its sessions; the UI gets the cache right
  /// away when none is connected.
  void _handleRefreshSessions() {
    var asked = false;
    for (final l in _links.values) {
      if (l.requestSessions()) asked = true;
    }
    if (!asked) _sendSessions();
  }

  Future<void> _onSessions(PcLink link, List<CcSession> sessions) async {
    final pc = link.pc;
    _sessions.removeWhere((e) => e.pcId == pc.id);
    _sessions.addAll([for (final s in sessions) SessionEntry(pcId: pc.id, pcName: pc.name, session: s)]);
    _sortSessions();
    _scheduleSessionsSave();
    _sendSessions();
  }

  Future<void> _onSession(PcLink link, CcSession session) async {
    final pc = link.pc;
    final entry = SessionEntry(pcId: pc.id, pcName: pc.name, session: session);
    final i = _sessions.indexWhere((e) => e.key == entry.key);
    if (i >= 0) {
      _sessions[i] = entry;
    } else {
      _sessions.add(entry);
    }
    _sortSessions();
    _scheduleSessionsSave();
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'session',
      'pc_id': pc.id,
      'pc_name': pc.name,
      'session': session.toJson(),
    }));
  }

  void _sortSessions() {
    _sessions.sort((a, b) => b.session.lastTs.compareTo(a.session.lastTs));
    if (_sessions.length > Store.maxSessions) {
      _sessions.removeRange(Store.maxSessions, _sessions.length);
    }
  }

  void _sendSessions() {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'sessions',
      'sessions': _sessions.map((e) => e.toJson()).toList(),
    }));
  }

  /// Throttled write of `sessions_cache` (at most one write per 1 s).
  void _scheduleSessionsSave() {
    if (_sessionsSaveTimer?.isActive ?? false) return;
    _sessionsSaveTimer = Timer(const Duration(seconds: 1), () {
      _sessionsSaveTimer = null;
      unawaited(_queueSessionsSave());
    });
  }

  Future<void> _queueSessionsSave() {
    final snapshot = List<SessionEntry>.of(_sessions);
    _sessionsSaveChain = _sessionsSaveChain
        .then((_) => Store.saveSessions(snapshot))
        .catchError((Object e) {
      debugPrint('ccnotify: saving sessions failed: $e');
    });
    return _sessionsSaveChain;
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
    if (_sessions.any((e) => !ids.contains(e.pcId))) {
      _sessions.removeWhere((e) => !ids.contains(e.pcId));
      _scheduleSessionsSave();
      _sendSessions();
    }
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
        onSessions: _onSessions,
        onSession: _onSession,
        onChat: _onChat,
        onSendResult: _onSendResult,
      );
      _links[pc.id] = link;
      link.start();
    }
    _sendStatus(force: true);
    _sendRequests();
  }

  void _onLinkState(PcLink link) {
    _sendStatus();
    if (link.state == PcStatus.connected) _flushOutbox(link);
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
    final key = requestKey(pcId, requestId);
    if (_requests.any((r) => r.key == key)) {
      await _dropRequests((r) => r.key == key, by: by);
    } else {
      // Not listed here (e.g. from a previous run): the UI may still show it.
      _notified.remove(key);
      _sendResolved(pcId, requestId, by);
    }
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
      _sendResolved(r.pcId, r.request.id, by);
    }
    _sendRequests();
    for (final r in gone) {
      await _cancelRequestNotification(r.pcId, r.request.id);
      await _cancelPromptNotifications(r.pcId, r.request.session);
    }
  }

  /// Tells the UI a request is gone (it drops it and closes its answer screen).
  void _sendResolved(String pcId, String requestId, String by) {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'resolved',
      'pc_id': pcId,
      'request_id': requestId,
      'by': by,
    }));
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

  /// Same id as [_notifyRequest] shows it with. Tried even when this run's
  /// init failed: the notification may be from a previous run.
  Future<void> _cancelRequestNotification(String pcId, String requestId) async {
    try {
      await _notifs.cancel(id: requestNotificationId(pcId, requestId));
    } catch (_) {}
  }

  /// A `needs_input` notification (permission prompt / elicitation) of
  /// [session] is stale once its request is resolved: Claude no longer waits.
  Future<void> _cancelPromptNotifications(String pcId, String session) async {
    if (session.isEmpty) return;
    final cutoff = DateTime.now().millisecondsSinceEpoch - _requestMaxAge.inMilliseconds;
    final ids = <int>[
      for (final h in _events)
        if (h.pcId == pcId &&
            h.event.kind == EventKind.needsInput &&
            h.event.session == session &&
            h.event.ts >= cutoff &&
            (h.event.detail == 'permission_prompt' || h.event.detail == 'elicitation_dialog'))
          notificationIdFor(pcId, h.event.id),
    ];
    for (final id in ids) {
      try {
        await _notifs.cancel(id: id);
      } catch (_) {}
    }
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
    // v1.2: a stop of a known session can be answered inline.
    final canReply = ev.kind == EventKind.stop && ev.sessionId.isNotEmpty;
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
        actions: canReply ? <fln.AndroidNotificationAction>[replyAction()] : null,
      ),
    );
    await _notifs.show(
      id: notificationIdFor(pc.id, ev.id),
      title: title,
      body: body.isEmpty ? null : body,
      notificationDetails: details,
      payload: EventPayload(
        pcId: pc.id,
        sessionId: ev.sessionId,
        eventId: ev.id,
        kind: ev.kind,
        title: title,
        pcName: pc.name,
      ).encode(),
    );
  }
}
