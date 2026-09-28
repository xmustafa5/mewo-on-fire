import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// SharedPreferencesAsync helpers. No cache, so values are always read fresh
/// from the platform store — safe to use from both the UI isolate and the
/// foreground-task isolate.
///
/// Key ownership (one writer per key):
/// - UI isolate:   `pcs`, `settings`, `first_launch_done`
/// - Task isolate: `events`, `since_<pcId>`, `hosts_<pcId>`, `pending_requests`
///
/// The one exception is `queued_answer_<pcId>_<requestId>`: an answer that
/// could not be handed to the task isolate directly. It is created by the
/// notification-action isolate (task port not registered) or by the UI isolate
/// (service not running) — one key per answer, so creators never overwrite
/// each other's lists — and only read + removed by the task isolate, which
/// drains the queue on start and on every repeat event.
class Store {
  static const kPcs = 'pcs';
  static const kSettings = 'settings';
  static const kEvents = 'events';
  static const kPendingRequests = 'pending_requests';
  static const kFirstLaunchDone = 'first_launch_done';
  static const kQueuedAnswerPrefix = 'queued_answer_';
  static const maxEvents = 300;

  static String sinceKey(String pcId) => 'since_$pcId';
  static String hostsKey(String pcId) => 'hosts_$pcId';
  static String queuedAnswerKey(String pcId, String requestId) =>
      '$kQueuedAnswerPrefix${pcId}_$requestId';

  static SharedPreferencesAsync? _instance;
  static SharedPreferencesAsync get _p => _instance ??= SharedPreferencesAsync();

  static Object? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  // ---- pcs (UI writes) ----
  static Future<List<PairedPc>> loadPcs() async {
    final d = _decode(await _p.getString(kPcs));
    if (d is! List) return <PairedPc>[];
    final out = <PairedPc>[];
    for (final e in d) {
      if (e is Map) {
        try {
          out.add(PairedPc.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {}
      }
    }
    return out;
  }

  static Future<void> savePcs(List<PairedPc> pcs) =>
      _p.setString(kPcs, jsonEncode(pcs.map((e) => e.toJson()).toList()));

  // ---- settings (UI writes) ----
  static Future<AppSettings> loadSettings() async {
    final d = _decode(await _p.getString(kSettings));
    if (d is! Map) return const AppSettings();
    return AppSettings.fromJson(Map<String, dynamic>.from(d));
  }

  static Future<void> saveSettings(AppSettings s) =>
      _p.setString(kSettings, jsonEncode(s.toJson()));

  static Future<bool> firstLaunchDone() async => (await _p.getBool(kFirstLaunchDone)) ?? false;

  static Future<void> setFirstLaunchDone() => _p.setBool(kFirstLaunchDone, true);

  // ---- events (task writes) ----
  static Future<List<HistoryEntry>> loadEvents() async {
    final d = _decode(await _p.getString(kEvents));
    if (d is! List) return <HistoryEntry>[];
    final out = <HistoryEntry>[];
    for (final e in d) {
      if (e is Map) {
        try {
          out.add(HistoryEntry.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {}
      }
    }
    return out;
  }

  static Future<void> saveEvents(List<HistoryEntry> events) {
    final list = events.length > maxEvents ? events.sublist(0, maxEvents) : events;
    return _p.setString(kEvents, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ---- pending requests (task writes) ----
  static Future<List<PendingRequest>> loadPendingRequests() async {
    final d = _decode(await _p.getString(kPendingRequests));
    if (d is! List) return <PendingRequest>[];
    final out = <PendingRequest>[];
    for (final e in d) {
      if (e is Map) {
        try {
          final r = PendingRequest.fromJson(Map<String, dynamic>.from(e));
          if (r.pcId.isNotEmpty && r.request.id.isNotEmpty) out.add(r);
        } catch (_) {}
      }
    }
    return out;
  }

  static Future<void> savePendingRequests(List<PendingRequest> requests) => _p.setString(
      kPendingRequests, jsonEncode(requests.map((e) => e.toJson()).toList()));

  // ---- queued answers (see the ownership note above) ----

  /// Stores `{"pc_id", "request_id", "answer"}` for the task isolate to send.
  static Future<void> queueAnswer(String pcId, String requestId, Map<String, dynamic> answer) =>
      _p.setString(
        queuedAnswerKey(pcId, requestId),
        jsonEncode({'pc_id': pcId, 'request_id': requestId, 'answer': answer}),
      );

  /// Task isolate only: returns and removes every queued answer.
  static Future<List<Map<String, dynamic>>> takeQueuedAnswers() async {
    final out = <Map<String, dynamic>>[];
    final keys = await _p.getKeys();
    for (final k in keys) {
      if (!k.startsWith(kQueuedAnswerPrefix)) continue;
      final d = _decode(await _p.getString(k));
      await _p.remove(k);
      if (d is Map) out.add(Map<String, dynamic>.from(d));
    }
    return out;
  }

  // ---- per-PC link state (task writes) ----
  static Future<int?> loadSince(String pcId) => _p.getInt(sinceKey(pcId));

  static Future<void> saveSince(String pcId, int since) => _p.setInt(sinceKey(pcId), since);

  static Future<List<String>?> loadHosts(String pcId) => _p.getStringList(hostsKey(pcId));

  static Future<void> saveHosts(String pcId, List<String> hosts) =>
      _p.setStringList(hostsKey(pcId), hosts);

  static Future<void> removeHosts(String pcId) => _p.remove(hostsKey(pcId));

  static Future<void> removePcState(String pcId) async {
    await _p.remove(sinceKey(pcId));
    await _p.remove(hostsKey(pcId));
  }

  /// Removes `since_*` / `hosts_*` keys of PCs that are no longer paired.
  static Future<void> removeOrphanPcState(Set<String> pairedIds) async {
    final keys = await _p.getKeys();
    for (final k in keys) {
      String? id;
      if (k.startsWith('since_')) id = k.substring(6);
      if (k.startsWith('hosts_')) id = k.substring(6);
      if (id != null && !pairedIds.contains(id)) {
        await _p.remove(k);
      }
    }
  }
}
