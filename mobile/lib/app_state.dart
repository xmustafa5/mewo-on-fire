import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:path_provider/path_provider.dart';

import 'background.dart';
import 'ios_background.dart';
import 'models.dart';
import 'requests.dart';
import 'sessions.dart';
import 'storage.dart';

/// A request to show on the answer screen.
class RequestRef {
  const RequestRef(this.pcId, this.requestId);
  final String pcId;
  final String requestId;
}

/// A session whose chat to show.
class SessionRef {
  const SessionRef(this.pcId, this.sessionId);
  final String pcId;
  final String sessionId;
}

/// A session's chat as last fetched (in memory only, never persisted).
class ChatState {
  String title = '';
  List<ChatItem> items = const <ChatItem>[];
  bool loaded = false;
  bool loading = false;
  String error = '';
}

/// A message sent from this phone, until the chat shows it (or forever when
/// rejected — rejected messages never reach the transcript).
class OutgoingMessage {
  OutgoingMessage({
    required this.clientId,
    required this.text,
    required this.ts,
    this.images = const <Uint8List>[],
  });

  final String clientId;
  final String text;
  final int ts; // unix ms
  final List<Uint8List> images;
  String status = SendStatus.sending;
  String reason = '';
}

/// An image of a chat, fetched from the PC on demand (in memory only).
class ChatImage {
  Uint8List? bytes;
  bool loading = false;
  String error = '';
}

/// UI-isolate state. Only writer of `pcs` and `settings`; talks to the task
/// isolate via `{"cmd": ...}` messages and receives status / event / requests /
/// sessions / chat / send_result messages. `pending_requests` and
/// `sessions_cache` are owned by the task: [requests] and [sessions] are copies.
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

  /// Sessions of all PCs, newest first.
  List<SessionEntry> sessions = <SessionEntry>[];

  /// Set when an event notification with a session is tapped; the app shell
  /// opens the chat screen and resets it to null.
  final ValueNotifier<SessionRef?> openSession = ValueNotifier<SessionRef?>(null);

  final Map<String, ChatState> _chats = <String, ChatState>{};

  /// v1.7 (TORCH policy): features by PC, and the policy requests waiting
  /// for the PC's answer, by client id.
  final Map<String, FeaturesData> _features = <String, FeaturesData>{};
  final Map<String, Completer<Map<String, dynamic>>> _policyWaits = <String, Completer<Map<String, dynamic>>>{};
  final Map<String, ScanReport> _scans = <String, ScanReport>{};

  /// Artifact files on their way from a PC (v1.6), by client id.
  final Map<String, _ArtifactFetch> _artifactFetches = <String, _ArtifactFetch>{};

  /// New sessions asked of a PC (v1.6), by client id, until it answers.
  final Map<String, Completer<String>> _newSessions = <String, Completer<String>>{};

  /// Pull requests by session key (v1.6), while a chat is open.
  final Map<String, PrList> _prs = <String, PrList>{};
  final Map<String, Timer> _prsTimers = <String, Timer>{};
  final Map<String, Timer> _prsTimeouts = <String, Timer>{};
  static const Duration _prsEvery = Duration(minutes: 2);

  /// Fetched chat images by `pcId|sessionId|imageId`, oldest first.
  final Map<String, ChatImage> _images = <String, ChatImage>{};
  final Map<String, Timer> _imageTimeouts = <String, Timer>{};
  static const int _maxCachedImages = 40;
  final Map<String, List<OutgoingMessage>> _outgoing = <String, List<OutgoingMessage>>{};
  final Map<String, int> _watched = <String, int>{}; // open chat screens by session key
  final Map<String, Timer> _chatRefreshTimers = <String, Timer>{};
  final Map<String, Timer> _chatTimeouts = <String, Timer>{};
  final Map<String, List<Completer<void>>> _chatWaiters = <String, List<Completer<void>>>{};
  final List<Completer<void>> _sessionsWaiters = <Completer<void>>[];

  bool serviceRunning = false;
  bool loaded = false;
  bool _initStarted = false;
  bool _userStopped = false; // user pressed Stop: don't auto-restart on resume
  final fln.FlutterLocalNotificationsPlugin _notifs = fln.FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addObserver(this);
    try {
      // Same callbacks as the task isolate (see CcTaskHandler._initNotifications).
      await _notifs.initialize(
        settings: kNotificationInitSettings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: onNotificationResponseBackground,
      );
    } catch (e) {
      debugPrint('mewo: notifications init failed: $e');
    }
    try {
      pcs = await Store.loadPcs();
      settings = await Store.loadSettings();
      events = await Store.loadEvents();
      requests = await Store.loadPendingRequests();
      sessions = await Store.loadSessions();
    } catch (e) {
      debugPrint('mewo: loading state failed: $e');
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
    _applyKeepAlive();
  }

  /// iOS: stay running in the background only while there is something to
  /// stay connected to.
  void _applyKeepAlive() {
    unawaited(setIosKeepAlive(settings.keepAlive && serviceRunning && pcs.isNotEmpty));
  }

  /// Taps on a notification while the app runs (and the cold-start tap).
  /// Action buttons normally go to [onNotificationResponseBackground]; they
  /// are handled here too in case a platform delivers them to the UI.
  void _onNotificationResponse(fln.NotificationResponse response) {
    final ep = EventPayload.tryParse(response.payload);
    if (ep != null) {
      final actionId = response.actionId;
      if (actionId != null && actionId.isNotEmpty) {
        unawaited(_routeReply(response));
        return;
      }
      if (ep.sessionId.isNotEmpty &&
          response.notificationResponseType == fln.NotificationResponseType.selectedNotification) {
        openSession.value = SessionRef(ep.pcId, ep.sessionId);
      }
      return;
    }
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

  /// A Reply delivered to the UI isolate (normally it goes to the background
  /// handler): same route; start the service if the message had to be queued.
  Future<void> _routeReply(fln.NotificationResponse response) async {
    await routeActionReply(response);
    if (pcs.isNotEmpty && !await _isRunning()) await startService();
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
      debugPrint('mewo: permission request failed: $e');
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

  /// Something outside the app's screens needs the PCs now (the watch asked
  /// while the app was in the background): connect again without waiting for
  /// the next retry.
  Future<void> wake() async {
    if (pcs.isEmpty) return;
    if (await _isRunning()) {
      serviceRunning = true;
      _send('reconnect');
    } else if (!_userStopped) {
      await startService();
    }
  }

  Future<bool> _isRunning() async {
    try {
      return await isServiceRunning();
    } catch (_) {
      return false;
    }
  }

  void _send(String cmd) {
    try {
      sendToTask(jsonEncode({'cmd': cmd}));
    } catch (e) {
      debugPrint('mewo: sendDataToTask($cmd) failed: $e');
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
      // After a reply was delivered, Claude's answer shows up with its stop.
      if (ev.kind == EventKind.stop && ev.sessionId.isNotEmpty) {
        _scheduleChatRefresh(pcId, ev.sessionId);
        // It may have pushed or opened a pull request meanwhile.
        if (_watched.containsKey(sessionKey(pcId, ev.sessionId))) {
          Timer(const Duration(seconds: 3), () => refreshPrs(pcId, ev.sessionId));
        }
      }
      notifyListeners();
    } else if (type == 'requests') {
      requests = _parseRequests(msg['requests']);
      notifyListeners();
    } else if (type == 'resolved') {
      final pcId = '${msg['pc_id']}';
      final requestId = '${msg['request_id']}';
      final key = requestKey(pcId, requestId);
      resolvedBy[key] = msg['by'] is String ? msg['by'] as String : '';
      if (resolvedBy.length > 50) resolvedBy.remove(resolvedBy.keys.first);
      requests = requests.where((r) => r.key != key).toList();
      notifyListeners();
      // The task cancels it too; harmless if it is already gone.
      unawaited(_cancelRequestNotification(pcId, requestId));
    } else if (type == 'sessions') {
      _onSessionsSnapshot(_parseSessions(msg['sessions']));
    } else if (type == 'session') {
      _onSessionUpdate(msg);
    } else if (type == 'chat') {
      _onChat(msg);
    } else if (type == 'chat_error') {
      final key = sessionKey('${msg['pc_id']}', '${msg['session_id']}');
      _finishChat(key, error: msg['error'] is String ? msg['error'] as String : 'Failed');
    } else if (type == 'image') {
      _onImage(msg);
    } else if (type == 'prs') {
      _onPrs(msg);
    } else if (type == 'artifact_file' || type == 'artifact_end') {
      _onArtifactFrame(msg);
    } else if (type == 'features') {
      _onFeatures(msg);
    } else if (type is String && type.endsWith('_result') && type != 'new_session_result') {
      final c = _policyWaits.remove('${msg['client_id']}');
      c?.complete(msg);
    } else if (type == 'new_session_result') {
      final c = _newSessions.remove('${msg['client_id']}');
      c?.complete(msg['ok'] == true ? '' : (msg['error'] is String && (msg['error'] as String).isNotEmpty ? msg['error'] as String : 'The PC could not start it'));
    } else if (type == 'send_result') {
      _onSendResult(msg);
    }
  }

  // ---- chat images (v1.3) ----

  static String _imageKey(String pcId, String sessionId, String imageId) =>
      '$pcId|$sessionId|$imageId';

  /// The image's state; starts fetching it when it is not there yet (or
  /// failed and [retry] is set).
  ChatImage chatImage(String pcId, String sessionId, String imageId, {bool retry = false}) {
    final key = _imageKey(pcId, sessionId, imageId);
    var image = _images[key];
    if (image != null && (image.bytes != null || image.loading || (image.error.isNotEmpty && !retry))) {
      return image;
    }
    image = ChatImage()..loading = true;
    _images.remove(key);
    _images[key] = image;
    while (_images.length > _maxCachedImages) {
      _images.remove(_images.keys.first);
    }
    _imageTimeouts[key]?.cancel();
    _imageTimeouts[key] = Timer(const Duration(seconds: 20), () => _finishImage(key, error: 'No answer'));
    unawaited(_requestImage(key, pcId, sessionId, imageId));
    return image;
  }

  Future<void> _requestImage(String key, String pcId, String sessionId, String imageId) async {
    if (!await _isRunning()) {
      _finishImage(key, error: 'Not connected');
      return;
    }
    try {
      sendToTask(jsonEncode(
          {'cmd': 'get_image', 'pc_id': pcId, 'session_id': sessionId, 'image_id': imageId}));
    } catch (_) {
      _finishImage(key, error: 'Not connected');
    }
  }

  void _onImage(Map<String, dynamic> msg) {
    final key = _imageKey('${msg['pc_id']}', '${msg['session_id']}', '${msg['image_id']}');
    final data = msg['data'];
    if (data is String && data.isNotEmpty) {
      try {
        _finishImage(key, bytes: base64Decode(data));
        return;
      } catch (_) {}
    }
    _finishImage(key, error: msg['error'] == 'offline' ? 'PC offline' : 'Not available');
  }

  /// Fetches an image again after it failed.
  void retryChatImage(String pcId, String sessionId, String imageId) {
    chatImage(pcId, sessionId, imageId, retry: true);
    notifyListeners();
  }

  void _finishImage(String key, {Uint8List? bytes, String error = ''}) {
    _imageTimeouts.remove(key)?.cancel();
    final image = _images[key];
    if (image == null || !image.loading) return;
    image.loading = false;
    image.bytes = bytes;
    image.error = bytes == null ? error : '';
    notifyListeners();
  }

  // ---- sessions + chat (task owns `sessions_cache`; chats live in memory) ----

  static List<SessionEntry> _parseSessions(Object? list) {
    final out = <SessionEntry>[];
    if (list is! List) return out;
    for (final e in list) {
      if (e is! Map) continue;
      try {
        final s = SessionEntry.fromJson(Map<String, dynamic>.from(e));
        if (s.pcId.isNotEmpty && s.session.id.isNotEmpty) out.add(s);
      } catch (_) {}
    }
    return out;
  }

  void _onSessionsSnapshot(List<SessionEntry> list) {
    final before = <String, CcSession>{for (final e in sessions) e.key: e.session};
    sessions = list;
    // Open chats refresh when their session changed or the last fetch failed
    // (e.g. the PC just reconnected).
    for (final e in list) {
      if (!_watched.containsKey(e.key)) continue;
      final old = before[e.key];
      final chat = _chats[e.key];
      if (old == null ||
          old.lastTs != e.session.lastTs ||
          old.state != e.session.state ||
          (chat != null && chat.error.isNotEmpty)) {
        _scheduleChatRefresh(e.pcId, e.session.id);
      }
    }
    for (final c in _sessionsWaiters) {
      if (!c.isCompleted) c.complete();
    }
    _sessionsWaiters.clear();
    notifyListeners();
  }

  void _onSessionUpdate(Map<String, dynamic> msg) {
    final raw = msg['session'];
    if (raw is! Map) return;
    final s = CcSession.fromJson(Map<String, dynamic>.from(raw));
    final pcId = '${msg['pc_id']}';
    if (s.id.isEmpty || pcId.isEmpty) return;
    final pcName = msg['pc_name'] is String ? msg['pc_name'] as String : pcNameFor(pcId);
    final entry = SessionEntry(pcId: pcId, pcName: pcName, session: s);
    final list = sessions.where((e) => e.key != entry.key).toList()
      ..add(entry)
      ..sort((a, b) => b.session.lastTs.compareTo(a.session.lastTs));
    sessions = list;
    _scheduleChatRefresh(pcId, s.id);
    notifyListeners();
  }

  void _onChat(Map<String, dynamic> msg) {
    final key = sessionKey('${msg['pc_id']}', '${msg['session_id']}');
    final chat = _chats.putIfAbsent(key, ChatState.new);
    final items = <ChatItem>[];
    final raw = msg['items'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final item = ChatItem.fromJson(Map<String, dynamic>.from(e));
        if (item.text.isNotEmpty || item.role == ChatRole.tool) items.add(item);
      }
    }
    chat.items = items;
    if (msg['title'] is String && (msg['title'] as String).isNotEmpty) {
      chat.title = msg['title'] as String;
    }
    chat.loaded = true;
    _finishChat(key);
  }

  /// Ends a pending chat fetch: stops the spinner, completes the waiters.
  void _finishChat(String key, {String error = ''}) {
    _chatTimeouts.remove(key)?.cancel();
    final chat = _chats.putIfAbsent(key, ChatState.new);
    chat.loading = false;
    chat.error = error;
    for (final c in _chatWaiters.remove(key) ?? const <Completer<void>>[]) {
      if (!c.isCompleted) c.complete();
    }
    notifyListeners();
  }

  void _onSendResult(Map<String, dynamic> msg) {
    final clientId = '${msg['client_id']}';
    final status = msg['status'] is String ? msg['status'] as String : '';
    final reason = msg['reason'] is String ? msg['reason'] as String : '';
    for (final list in _outgoing.values) {
      for (final m in list) {
        if (m.clientId != clientId) continue;
        m.status = status.isEmpty ? SendStatus.rejected : status;
        m.reason = reason;
        notifyListeners();
        return;
      }
    }
  }

  SessionEntry? findSession(String pcId, String sessionId) {
    final key = sessionKey(pcId, sessionId);
    for (final e in sessions) {
      if (e.key == key) return e;
    }
    return null;
  }

  ChatState? chatOf(String pcId, String sessionId) => _chats[sessionKey(pcId, sessionId)];

  /// What to offer as the next message (v1.5): the suggestions of Claude's
  /// reply while it is the last thing in the chat and Claude is not working.
  List<String> suggestionsOf(String pcId, String sessionId) {
    final items = chatOf(pcId, sessionId)?.items ?? const <ChatItem>[];
    if (items.isEmpty || items.last.role != ChatRole.assistant) return const <String>[];
    final session = findSession(pcId, sessionId)?.session;
    if (session != null && (session.state == SessionState.working || session.ended)) {
      return const <String>[];
    }
    if (outgoingOf(pcId, sessionId).any((m) => m.status != SendStatus.rejected)) {
      return const <String>[]; // something was sent after it
    }
    return items.last.suggestions;
  }

  List<OutgoingMessage> outgoingOf(String pcId, String sessionId) =>
      _outgoing[sessionKey(pcId, sessionId)] ?? const <OutgoingMessage>[];

  /// A chat screen for the session opened: fetch now, and auto-refresh on
  /// `session` updates and `stop` events until [unwatchChat].
  void watchChat(String pcId, String sessionId) {
    final key = sessionKey(pcId, sessionId);
    _watched[key] = (_watched[key] ?? 0) + 1;
    // Not synchronously: called from initState (during a build), and
    // refreshChat notifies listeners.
    unawaited(Future<void>.microtask(() {
      refreshChat(pcId, sessionId);
      refreshPrs(pcId, sessionId);
    }));
    _prsTimers[key]?.cancel();
    _prsTimers[key] = Timer.periodic(_prsEvery, (_) => refreshPrs(pcId, sessionId));
  }

  void unwatchChat(String pcId, String sessionId) {
    final key = sessionKey(pcId, sessionId);
    final n = (_watched[key] ?? 0) - 1;
    if (n > 0) {
      _watched[key] = n;
      return;
    }
    _watched.remove(key);
    _chatRefreshTimers.remove(key)?.cancel();
    _prsTimers.remove(key)?.cancel();
  }

  // ---- the TORCH flow (v1.7) ----

  FeaturesData? featuresOf(String pcId) => _features[pcId];

  /// Every feature of every PC, newest activity first.
  List<(String, TorchFeature)> get allFeatures {
    final out = <(String, TorchFeature)>[];
    for (final e in _features.entries) {
      for (final f in e.value.features) {
        out.add((e.key, f));
      }
    }
    out.sort((a, b) {
      final ra = a.$2.running ? 0 : 1;
      final rb = b.$2.running ? 0 : 1;
      if (ra != rb) return ra - rb;
      return a.$2.key.compareTo(b.$2.key);
    });
    return out;
  }

  ScanReport? scanOf(String pcId, String sessionId) => _scans[sessionKey(pcId, sessionId)];

  /// Asks every PC for its features.
  Future<void> refreshFeatures() async {
    for (final pc in pcs) {
      try {
        sendToTask(jsonEncode({'cmd': 'policy', 'pc_id': pc.id, 'frame': {'type': 'get_features', 'client_id': _clientId()}}));
      } catch (_) {}
    }
  }

  void _onFeatures(Map<String, dynamic> msg) {
    final pcId = '${msg['pc_id']}';
    if (pcId.isEmpty) return;
    final hadPlane = _features[pcId]?.plane.configured ?? false;
    if (msg['ok'] != false && msg['plane'] is Map && (msg['plane'] as Map)['configured'] == true && !hadPlane) {
      Timer(const Duration(milliseconds: 300), refreshMine);
    }
    if (msg['ok'] == false && _features.containsKey(pcId)) {
      // Keep what was known; the error shows on the list.
      final old = _features[pcId]!;
      _features[pcId] = FeaturesData(features: old.features, selfCheck: old.selfCheck, reviewCheck: old.reviewCheck, error: '${msg['error'] ?? ''}', ts: old.ts, workspaces: old.workspaces, roles: old.roles, apps: old.apps, roleNames: old.roleNames, warning: old.warning, plane: old.plane);
    } else {
      _features[pcId] = FeaturesData.fromJson(msg);
    }
    notifyListeners();
  }

  String _clientId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// A policy frame to [pcId], answered by its `*_result`. The map has
  /// `ok` and, when false, `error`.
  Future<Map<String, dynamic>> policy(String pcId, String type, Map<String, dynamic> params) async {
    if (!await _isRunning()) return {'ok': false, 'error': 'The background service is stopped. Start it on Home.'};
    final clientId = _clientId();
    final c = Completer<Map<String, dynamic>>();
    _policyWaits[clientId] = c;
    try {
      sendToTask(jsonEncode({'cmd': 'policy', 'pc_id': pcId, 'frame': {...params, 'type': type, 'client_id': clientId}}));
    } catch (_) {
      _policyWaits.remove(clientId);
      return {'ok': false, 'error': 'Could not reach the background service'};
    }
    final r = await c.future.timeout(const Duration(seconds: 30), onTimeout: () => {'ok': false, 'error': 'No answer from ${pcNameFor(pcId)}'});
    _policyWaits.remove(clientId);
    return r;
  }

  /// Signs a gate; refreshes the features after.
  Future<String> sign(String pcId, TorchFeature f, TorchGate g, String role, String name, List<bool> checks) async {
    final r = await policy(pcId, 'sign', {'feature': f.key, 'workspace': f.workspace, 'gate': g.id, 'role': role, 'name': name, 'checks': checks});
    if (r['ok'] == true) {
      if (name.trim().isNotEmpty && name.trim() != settings.signerName) await updateSettings(settings.copyWith(signerName: name.trim()));
      unawaited(refreshFeatures());
      final note = '${r['note'] ?? ''}';
      return note;
    }
    throw StateError('${r['error'] ?? 'The PC could not sign it'}');
  }

  Future<String> requestSign(String pcId, TorchFeature f, TorchGate g, String role) async {
    final r = await policy(pcId, 'request_sign', {'feature': f.key, 'workspace': f.workspace, 'gate': g.id, 'role': role, 'name': settings.signerName});
    return r['ok'] == true ? '' : '${r['error'] ?? 'Could not ask'}';
  }

  /// Starts a planned session in Claude Desktop on the PC.
  Future<String> startPlanSession(String pcId, TorchFeature f, int n) async {
    final r = await policy(pcId, 'start_session', {'feature': f.key, 'workspace': f.workspace, 'n': n});
    if (r['ok'] == true) {
      Timer(const Duration(seconds: 4), refreshSessions);
      Timer(const Duration(seconds: 5), refreshFeatures);
      return '';
    }
    return '${r['error'] ?? 'The PC could not start it'}';
  }

  Future<String> setPlanStatus(String pcId, TorchFeature f, int n, String status) async {
    final r = await policy(pcId, 'plan_status', {'feature': f.key, 'workspace': f.workspace, 'n': n, 'status': status, 'pr': ''});
    if (r['ok'] == true) {
      unawaited(refreshFeatures());
      return '';
    }
    return '${r['error'] ?? 'Could not write the plan'}';
  }

  // ---- the flow runner (v1.8) ----

  Future<String> _flowCmd(String pcId, String type, Map<String, dynamic> params, {bool refresh = true}) async {
    final r = await policy(pcId, type, params);
    if (r['ok'] == true) {
      if (refresh) Timer(const Duration(milliseconds: 600), refreshFeatures);
      return '';
    }
    return '${r['error'] ?? 'The PC could not do it'}';
  }

  /// Does the flow's next action for [f] now. Empty string on success.
  Future<String> flowNext(String pcId, TorchFeature f) => _flowCmd(pcId, 'flow_next', {'feature': f.key, 'workspace': f.workspace, 'name': settings.signerName});

  Future<String> flowSet(String pcId, TorchFeature f, bool autopilot) => _flowCmd(pcId, 'flow_set', {'feature': f.key, 'workspace': f.workspace, 'autopilot': autopilot});

  Future<String> estimate(String pcId, TorchFeature f, String role, double days, String assumptions) =>
      _flowCmd(pcId, 'estimate', {'feature': f.key, 'workspace': f.workspace, 'role': role, 'name': settings.signerName, 'days': days, 'assumptions': assumptions});

  Future<String> estimatesDone(String pcId, TorchFeature f) => _flowCmd(pcId, 'estimates_done', {'feature': f.key, 'workspace': f.workspace});

  Future<String> exportHandoff(String pcId, TorchFeature f) => _flowCmd(pcId, 'export_handoff', {'feature': f.key, 'workspace': f.workspace});

  Future<Map<String, dynamic>> uatUser(String pcId, TorchFeature f, String user, String role, bool unaided, String notes) async {
    final r = await policy(pcId, 'uat_user', {'feature': f.key, 'workspace': f.workspace, 'user': user, 'role': role, 'unaided': unaided, 'notes': notes});
    if (r['ok'] == true) Timer(const Duration(milliseconds: 600), refreshFeatures);
    return r;
  }

  Future<String> release(String pcId, TorchFeature f) => _flowCmd(pcId, 'release', {'feature': f.key, 'workspace': f.workspace, 'name': settings.signerName});

  Future<Map<String, dynamic>> closeBranches(String pcId, TorchFeature f) async {
    final r = await policy(pcId, 'close_branches', {'feature': f.key, 'workspace': f.workspace});
    Timer(const Duration(milliseconds: 600), refreshFeatures);
    return r;
  }

  Future<Map<String, dynamic>> newFeature(String pcId, String workspace, String app, String slug, bool light) async {
    final r = await policy(pcId, 'new_feature', {'workspace': workspace, 'app': app, 'slug': slug, 'light': light});
    if (r['ok'] == true) Timer(const Duration(milliseconds: 600), refreshFeatures);
    return r;
  }

  // ---- Plane (v2.1) ----

  final Map<String, List<MineItem>> _mine = <String, List<MineItem>>{};

  List<MineItem> mineOf(String pcId) => _mine[pcId] ?? const <MineItem>[];

  /// Everything assigned to me in Plane, across PCs.
  List<(String, MineItem)> get allMine => [for (final e in _mine.entries) for (final m in e.value) (e.key, m)];

  /// Signs in with a Plane personal token on every PC that has Plane; the
  /// PC remembers this phone as that person. Returns the display name.
  Future<String> planeSignin(String token) async {
    String name = '';
    String error = '';
    for (final pc in pcs) {
      if (!(featuresOf(pc.id)?.plane.configured ?? false)) continue;
      final r = await policy(pc.id, 'plane_signin', {'token': token});
      if (r['ok'] == true) {
        name = '${(r['me'] as Map?)?['display'] ?? ''}';
      } else {
        error = '${r['error'] ?? ''}';
      }
    }
    if (name.isEmpty) throw StateError(error.isEmpty ? 'No PC has Plane connected yet (console → PLANE)' : error);
    if (name != settings.signerName) await updateSettings(settings.copyWith(signerName: name));
    unawaited(refreshMine());
    unawaited(refreshFeatures());
    return name;
  }

  Future<void> refreshMine() async {
    for (final pc in pcs) {
      if (!(featuresOf(pc.id)?.plane.configured ?? false)) continue;
      final r = await policy(pc.id, 'plane_mine', {});
      if (r['ok'] == true && r['items'] is List) {
        _mine[pc.id] = [for (final i in r['items'] as List) if (i is Map) MineItem.fromJson(Map<String, dynamic>.from(i))];
      } else {
        _mine.remove(pc.id);
      }
    }
    notifyListeners();
  }

  Future<List<PlaneTask>> planeTasks(String pcId, TorchFeature f, int n) async {
    final r = await policy(pcId, 'plane_tasks', {'feature': f.key, 'workspace': f.workspace, 'n': n});
    if (r['ok'] != true) throw StateError('${r['error'] ?? 'Could not read the tasks'}');
    return [for (final t in (r['tasks'] as List? ?? const [])) if (t is Map) PlaneTask.fromJson(Map<String, dynamic>.from(t))];
  }

  Future<String> planeTaskAdd(String pcId, TorchFeature f, int n, String name) async {
    final r = await policy(pcId, 'plane_task_add', {'feature': f.key, 'workspace': f.workspace, 'n': n, 'name': name});
    return r['ok'] == true ? '' : '${r['error'] ?? 'Could not add it'}';
  }

  Future<String> planeTaskDone(String pcId, String id, bool done) async {
    final r = await policy(pcId, 'plane_task_done', {'id': id, 'done': done});
    return r['ok'] == true ? '' : '${r['error'] ?? 'Could not change it'}';
  }

  /// Removes a signature from a gate (v1.9): precisely, even one made by hand.
  Future<String> unsign(String pcId, TorchFeature f, TorchGate g, String role) => _flowCmd(pcId, 'unsign', {'feature': f.key, 'workspace': f.workspace, 'gate': g.id, 'role': role});

  /// Rolls back one of the flow's writes (v1.9). Returns the PC's notes.
  Future<Map<String, dynamic>> rollback(String pcId, TorchFeature f, int id) async {
    final r = await policy(pcId, 'rollback', {'feature': f.key, 'workspace': f.workspace, 'id': id});
    Timer(const Duration(milliseconds: 600), refreshFeatures);
    return r;
  }

  /// v2.2: the PRD families a feature can follow: `(list, file in use, error)`.
  Future<(List<PrdChoice>, String, String)> prds(String pcId, TorchFeature f) async {
    final r = await policy(pcId, 'prds', {'feature': f.key, 'workspace': f.workspace});
    if (r['ok'] != true) return (const <PrdChoice>[], '', '${r['error'] ?? 'The PC could not list them'}');
    final list = <PrdChoice>[
      if (r['prds'] is List)
        for (final p in r['prds'] as List)
          if (p is Map) PrdChoice.fromJson(Map<String, dynamic>.from(p)),
    ];
    return (list, '${r['prd'] ?? ''}', '');
  }

  /// v2.2: points the feature at a PRD family; empty goes back to the name match.
  Future<String> setPrd(String pcId, TorchFeature f, String stem) => _flowCmd(pcId, 'set_prd', {'feature': f.key, 'workspace': f.workspace, 'prd': stem});

  /// Claims a role for the signer of this phone (the PC fills in the phone).
  Future<String> setRole(String pcId, String workspace, String role, String name) => _flowCmd(pcId, 'set_role', {'workspace': workspace, 'role': role, 'name': name, 'phone': ''});

  /// The self-check scan of a session's changes.
  Future<ScanReport> scan(String pcId, String sessionId) async {
    final r = await policy(pcId, 'get_scan', {'session_id': sessionId});
    final report = ScanReport.fromJson(r);
    _scans[sessionKey(pcId, sessionId)] = report;
    notifyListeners();
    return report;
  }

  /// One line of a session's self-check; the session push brings it back.
  Future<void> setCheck(String pcId, String sessionId, int index, bool checked) async {
    await policy(pcId, 'set_check', {'session_id': sessionId, 'index': index, 'checked': checked});
  }

  // ---- artifacts (v1.6) ----

  /// The files of [a] from [pcId], saved under the temp folder. Throws a
  /// [StateError] with the reason when they do not come.
  Future<ArtifactBundle> fetchArtifact(String pcId, String sessionId, SessionArtifact a) async {
    if (!await _isRunning()) throw StateError('The background service is stopped. Start it on Home.');
    final clientId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/mewo-artifacts/$pcId/${a.id.isEmpty ? clientId : a.id}');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final fetch = _ArtifactFetch(dir.path);
    _artifactFetches[clientId] = fetch;
    try {
      sendToTask(jsonEncode({'cmd': 'get_artifact', 'pc_id': pcId, 'client_id': clientId, 'session_id': sessionId, 'url': a.url, 'id': a.id, 'entry': a.entry, 'title': a.title}));
    } catch (_) {
      _artifactFetches.remove(clientId);
      throw StateError('Could not reach the background service');
    }
    try {
      return await fetch.done.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw StateError('No answer from ${pcNameFor(pcId)}'),
      );
    } finally {
      _artifactFetches.remove(clientId);
    }
  }

  void _onArtifactFrame(Map<String, dynamic> msg) {
    final fetch = _artifactFetches['${msg['client_id']}'];
    if (fetch == null) return;
    if (msg['type'] == 'artifact_file') {
      final path = '${msg['path'] ?? ''}';
      if (path.isEmpty || path.startsWith('/') || path.split('/').any((p) => p.isEmpty || p == '..')) return;
      final count = msg['parts'] is int && (msg['parts'] as int) > 0 ? msg['parts'] as int : 1;
      final part = msg['part'] is int ? msg['part'] as int : 0;
      final parts = fetch.parts.putIfAbsent(path, () => List<String?>.filled(count, null));
      if (part < 0 || part >= parts.length) return;
      parts[part] = '${msg['data'] ?? ''}';
      if (parts.any((p) => p == null)) return;
      final joined = parts.join();
      fetch.parts.remove(path);
      final bytes = msg['encoding'] == 'base64' ? base64Decode(joined) : utf8.encode(joined);
      fetch.writes.add(File('${fetch.dir}/$path').create(recursive: true).then((f) => f.writeAsBytes(bytes)).then((_) {}));
      return;
    }
    if (fetch.done.isCompleted) return;
    if (msg['ok'] != true) {
      final e = msg['error'];
      fetch.done.completeError(StateError(e is String && e.isNotEmpty ? e : 'The PC could not send it'));
      return;
    }
    Future.wait(fetch.writes).then((_) {
      if (fetch.done.isCompleted) return;
      fetch.done.complete(ArtifactBundle(
        dir: fetch.dir,
        entry: '${msg['entry'] ?? ''}',
        kind: '${msg['kind'] ?? ''}',
        title: '${msg['title'] ?? ''}',
      ));
    }, onError: (Object _) {
      if (!fetch.done.isCompleted) fetch.done.completeError(StateError('Could not save the files'));
    });
  }

  // ---- new sessions (v1.6) ----

  /// Asks [pcId] to start a Claude Code session in Claude Desktop with
  /// [prompt] as its first message, in [cwd] when given. Resolves to an
  /// empty string, or the reason it did not happen.
  Future<String> newSession(String pcId, {String cwd = '', required String prompt}) async {
    if (prompt.trim().isEmpty) return 'Write the first message';
    if (!await _isRunning()) return 'The background service is stopped. Start it on Home.';
    final clientId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final c = Completer<String>();
    _newSessions[clientId] = c;
    try {
      sendToTask(jsonEncode({'cmd': 'new_session', 'pc_id': pcId, 'client_id': clientId, 'cwd': cwd, 'prompt': prompt.trim()}));
    } catch (_) {
      _newSessions.remove(clientId);
      return 'Could not reach the background service';
    }
    final result = await c.future.timeout(const Duration(seconds: 20), onTimeout: () => 'No answer from ${pcNameFor(pcId)}');
    _newSessions.remove(clientId);
    if (result.isEmpty) {
      // Desktop sends the prompt; the hooks bring the session here.
      Timer(const Duration(seconds: 4), refreshSessions);
      Timer(const Duration(seconds: 12), refreshSessions);
    }
    return result;
  }

  // ---- pull requests (v1.6) ----

  PrList? prsOf(String pcId, String sessionId) => _prs[sessionKey(pcId, sessionId)];

  /// Asks the PC for the open pull requests of the session's repository.
  Future<void> refreshPrs(String pcId, String sessionId) async {
    final key = sessionKey(pcId, sessionId);
    final current = _prs[key] ?? const PrList();
    if (current.loading) return;
    _prs[key] = current.copyWith(loading: true);
    notifyListeners();
    _prsTimeouts[key]?.cancel();
    _prsTimeouts[key] = Timer(const Duration(seconds: 30), () {
      final c = _prs[key];
      if (c == null || !c.loading) return;
      _prs[key] = c.copyWith(loading: false, error: c.loaded ? c.error : 'No answer from ${pcNameFor(pcId)}');
      notifyListeners();
    });
    if (!await _isRunning()) {
      _prs[key] = current.copyWith(loading: false);
      notifyListeners();
      return;
    }
    try {
      sendToTask(jsonEncode({'cmd': 'get_prs', 'pc_id': pcId, 'session_id': sessionId}));
    } catch (_) {
      _prs[key] = current.copyWith(loading: false);
      notifyListeners();
    }
  }

  void _onPrs(Map<String, dynamic> msg) {
    final key = sessionKey('${msg['pc_id']}', '${msg['session_id']}');
    _prsTimeouts.remove(key)?.cancel();
    final fresh = PrList.fromJson(msg);
    final old = _prs[key];
    // A failed refresh keeps what was known, with the reason.
    _prs[key] = fresh.error.isNotEmpty && old != null && old.loaded && fresh.prs.isEmpty
        ? old.copyWith(loading: false, error: fresh.error)
        : fresh;
    notifyListeners();
  }

  void _scheduleChatRefresh(String pcId, String sessionId) {
    final key = sessionKey(pcId, sessionId);
    if (!_watched.containsKey(key)) return;
    _chatRefreshTimers[key]?.cancel();
    _chatRefreshTimers[key] = Timer(const Duration(milliseconds: 700), () {
      _chatRefreshTimers.remove(key);
      if (_watched.containsKey(key)) unawaited(refreshChat(pcId, sessionId));
    });
  }

  /// Fetches the session's chat; completes when it arrived or failed.
  Future<void> refreshChat(String pcId, String sessionId) async {
    final key = sessionKey(pcId, sessionId);
    final chat = _chats.putIfAbsent(key, ChatState.new);
    chat.loading = true;
    notifyListeners();
    final c = Completer<void>();
    (_chatWaiters[key] ??= <Completer<void>>[]).add(c);
    _chatTimeouts[key]?.cancel();
    _chatTimeouts[key] = Timer(const Duration(seconds: 20), () {
      _finishChat(key, error: 'No answer from ${pcNameFor(pcId)} — is Mewo on Fire up to date on the PC?');
    });
    if (!await _isRunning()) {
      _finishChat(key, error: 'The background service is stopped. Start it on the PCs tab.');
      return c.future;
    }
    try {
      sendToTask(jsonEncode({'cmd': 'get_chat', 'pc_id': pcId, 'session_id': sessionId}));
    } catch (_) {
      _finishChat(key, error: 'Could not reach the background service');
    }
    return c.future;
  }

  /// Asks the connected PCs for their sessions; completes when the list
  /// arrived (or after a few seconds).
  Future<void> refreshSessions() async {
    if (!await _isRunning()) return;
    final c = Completer<void>();
    _sessionsWaiters.add(c);
    _send('refresh_sessions');
    await c.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    _sessionsWaiters.remove(c);
  }

  /// Sends [text] (and [images], v1.3) to a session through the task
  /// isolate. When the service is not running, a text message is queued and
  /// the service started. Returns the message (its status changes as the PC
  /// answers), or null when there was nothing to send.
  Future<OutgoingMessage?> sendMessage(
    String pcId,
    String sessionId,
    String text, {
    List<Uint8List> images = const <Uint8List>[],
  }) async {
    final t = text.trim();
    if (t.isEmpty && images.isEmpty) return null;
    final key = sessionKey(pcId, sessionId);
    final m = OutgoingMessage(
      clientId: newClientId(),
      text: t,
      ts: DateTime.now().millisecondsSinceEpoch,
      images: images,
    );
    (_outgoing[key] ??= <OutgoingMessage>[]).add(m);
    notifyListeners();
    final msg = sendCmd(pcId, sessionId, t, m.clientId, images: [
      // The PC tells the format by the content.
      for (final bytes in images) {'mime': 'image/jpeg', 'data': base64Encode(bytes)},
    ]);
    if (await _isRunning()) {
      try {
        sendToTask(jsonEncode(msg));
        return m;
      } catch (e) {
        debugPrint('mewo: sending message failed: $e');
      }
    }
    if (images.isNotEmpty) {
      // Too big for the queue in the preferences: connect first.
      m.status = SendStatus.rejected;
      m.reason = 'Not connected to the PC yet — send it again in a moment';
      notifyListeners();
      if (pcs.isNotEmpty) await startService();
      return m;
    }
    try {
      await Store.queueSend(msg);
    } catch (_) {
      m.status = SendStatus.rejected;
      m.reason = 'Could not queue the message';
      notifyListeners();
      return m;
    }
    if (pcs.isNotEmpty) await startService();
    return m;
  }

  /// Drops a message that was rejected (it never reached the chat).
  void removeOutgoing(String pcId, String sessionId, String clientId) {
    _outgoing[sessionKey(pcId, sessionId)]?.removeWhere((m) => m.clientId == clientId);
    notifyListeners();
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
        sendToTask(jsonEncode(answerMessage(pcId, requestId, answer)));
        return;
      } catch (e) {
        debugPrint('mewo: sending answer failed: $e');
      }
    }
    try {
      await Store.queueAnswer(pcId, requestId, answer);
      await _cancelRequestNotification(pcId, requestId);
    } catch (e) {
      debugPrint('mewo: queueing answer failed: $e');
    }
    if (pcs.isNotEmpty) await startService();
  }

  /// Same id the task shows the request notification with.
  Future<void> _cancelRequestNotification(String pcId, String requestId) async {
    try {
      await _notifs.cancel(id: requestNotificationId(pcId, requestId));
    } catch (_) {}
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
    _applyKeepAlive();
  }

  Future<void> stopService({bool byUser = false}) async {
    if (byUser) _userStopped = true;
    try {
      await stopForegroundService();
    } catch (_) {}
    serviceRunning = await _isRunning();
    if (!serviceRunning) status = <String, String>{};
    notifyListeners();
    _applyKeepAlive();
  }

  // ---- pcs (UI is the only writer) ----

  Future<void> addPc(PairedPc pc) async {
    pcs = <PairedPc>[...pcs.where((p) => p.id != pc.id), pc];
    await Store.savePcs(pcs);
    status[pc.id] = PcStatus.connecting;
    notifyListeners();
    if (await _isRunning()) {
      _send('reload');
      _applyKeepAlive();
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
    _applyKeepAlive();
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
    _applyKeepAlive();
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

  // ---- cached chats (Settings → "Clear cached chats") ----

  /// Drops everything this phone remembers about sessions and chats: the
  /// session list, fetched chats and images, and the status of messages sent
  /// from here. The PCs are asked for their sessions again.
  Future<void> clearChats() async {
    _prs.clear();
    _chats.clear();
    _images.clear();
    for (final t in _imageTimeouts.values) {
      t.cancel();
    }
    _imageTimeouts.clear();
    _outgoing.clear();
    sessions = <SessionEntry>[];
    notifyListeners();
    if (await _isRunning()) {
      _send('clear_sessions');
    } else {
      // Task not running → no concurrent writer, safe to clear directly.
      await Store.saveSessions(<SessionEntry>[]);
    }
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

/// An artifact's files, fetched from the PC into a folder of the temp dir
/// (v1.6). [entry] is what to open inside it.
class ArtifactBundle {
  const ArtifactBundle({required this.dir, required this.entry, required this.kind, required this.title});

  final String dir;
  final String entry;
  final String kind;
  final String title;
}

class _ArtifactFetch {
  _ArtifactFetch(this.dir);

  final String dir;

  /// Chunks per file until all of them are there.
  final Map<String, List<String?>> parts = <String, List<String?>>{};
  final List<Future<void>> writes = <Future<void>>[];
  final Completer<ArtifactBundle> done = Completer<ArtifactBundle>();
}
