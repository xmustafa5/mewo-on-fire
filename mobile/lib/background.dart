import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;

import 'models.dart';
import 'pc_link.dart';
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

/// Stable, positive 31-bit id per (pc, event) — FNV-1a.
int notificationIdFor(String pcId, int eventId) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode('$pcId:$eventId')) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  var id = h & 0x7fffffff;
  if (id == 0 || id == kServiceId) id += 1;
  return id;
}

/// Owns all PC connections. Only writer of `events`, `since_<pcId>`,
/// `hosts_<pcId>`. Shows the system notifications.
class CcTaskHandler extends TaskHandler {
  final fln.FlutterLocalNotificationsPlugin _notifs = fln.FlutterLocalNotificationsPlugin();
  final Map<String, PcLink> _links = <String, PcLink>{};
  final Map<String, String> _pcSig = <String, String>{};
  final Completer<void> _ready = Completer<void>();

  AppSettings _settings = const AppSettings();
  List<HistoryEntry> _events = <HistoryEntry>[];
  bool _notifsReady = false;

  Future<void> _reloadChain = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();
  Timer? _saveTimer;
  String? _netSig;
  String _lastSummary = '';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await _initNotifications();
    } catch (e) {
      debugPrint('ccnotify: notifications init failed: $e');
    }
    try {
      _events = await Store.loadEvents();
    } catch (_) {}
    await _serialReload(cleanOrphans: true);
    _netSig = await _networkSignature();
    if (!_ready.isCompleted) _ready.complete();

    if (_links.isEmpty) {
      // Nothing to listen to (e.g. started on boot after all PCs were removed).
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (!_ready.isCompleted) return;
    unawaited(_checkNetwork());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    for (final l in _links.values) {
      await l.stop();
    }
    _links.clear();
    try {
      await _queueSave();
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    final cmd = _decodeCmd(data);
    if (cmd == null) return;
    _ready.future.then((_) => _handleCmd(cmd));
  }

  // ---- commands from the UI ----

  static String? _decodeCmd(Object data) {
    Object? d = data;
    if (d is String) {
      try {
        d = jsonDecode(d);
      } catch (_) {
        return null;
      }
    }
    if (d is Map && d['cmd'] is String) return d['cmd'] as String;
    return null;
  }

  Future<void> _handleCmd(String cmd) async {
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
    } else if (cmd == 'status') {
      _sendStatus(force: true);
    }
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
      final link = PcLink(pc: pc, onState: (_) => _sendStatus(), onEvent: _onEvent);
      _links[pc.id] = link;
      link.start();
    }
    _sendStatus(force: true);
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

  // ---- system notifications ----

  Future<void> _initNotifications() async {
    await _notifs.initialize(
      settings: const fln.InitializationSettings(
        android: fln.AndroidInitializationSettings('ic_stat_notify'),
        iOS: fln.DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    final android = _notifs.resolvePlatformSpecificImplementation<
        fln.AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(_chNeedsInput);
      await android.createNotificationChannel(_chStop);
      await android.createNotificationChannel(_chSessionEnd);
    }
    _notifsReady = true;
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
